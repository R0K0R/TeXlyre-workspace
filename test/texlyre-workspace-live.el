;;; texlyre-workspace-live.el --- Live test against a real relay  -*- lexical-binding: t; -*-

;; Not part of the ERT suite; started by test/live.py, which runs the relay
;; and a scripted browser.  Environment: TLW_RELAY, TLW_PROJECT,
;; TLW_BRIDGE (the TeXlyre_bridge binary), TLW_BASE (a scratch directory).
;; Flow: open -> wait for the layout -> type EMACS-MARK -> wait until the
;; browser's BROWSER-MARK arrives -> save -> quit.  Exit 0 on success.

(require 'texlyre-workspace)
(require 'ert)

(defvar TeX-output-dir)
(defvar tlw-live--failed nil)

(defun tlw-live--wait (pred &optional timeout what)
  (let ((deadline (+ (float-time) (or timeout 30))) r)
    (while (and (not (setq r (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (or r (error "timeout waiting for %s" (or what pred)))))

(defun tlw-live--check (what ok)
  (princ (format "%s %s\n" (if ok "PASS" "FAIL") what))
  (unless ok (setq tlw-live--failed t)))

(let* ((base (getenv "TLW_BASE"))
       (texlyre-workspace-mirror-directory (expand-file-name "mirror/" base))
       (texlyre-workspace-bridge-command (list (getenv "TLW_BRIDGE")))
       (texlyre-workspace-relays (list (list :name "live" :url (getenv "TLW_RELAY"))))
       (emacs-collab-layout-state-file (expand-file-name "layout.eld" base))
       (emacs-collab-layout-register-lsp nil)
       (TeX-output-dir "build")
       (unrelated (generate-new-buffer "*unrelated*")))
  (unwind-protect
      (let* ((conn (texlyre-open-project "live" (getenv "TLW_PROJECT")))
             (s (car texlyre-workspace--sessions))
             (mirror (texlyre-workspace-session-mirror s)))
        (tlw-live--wait (lambda () (emacs-collab-layout-project mirror)) 30 "layout")
        (tlw-live--check "ready and layout built" (emacs-collab-conn-ready conn))
        (tlw-live--check "roles tree/editor/terminal/pdf"
                         (and (emacs-collab-layout-window 'tree) (emacs-collab-layout-window 'editor)
                              (emacs-collab-layout-window 'terminal) (emacs-collab-layout-window 'pdf)))
        (let* ((main (texlyre-workspace-session-main s))
               (ebuf (window-buffer (emacs-collab-layout-window 'editor))))
          (tlw-live--check "main file is main.tex from the browser's text"
                           (and (equal main (expand-file-name "main.tex" mirror))
                                (equal (buffer-file-name ebuf) main)
                                (with-current-buffer ebuf
                                  (save-excursion (goto-char (point-min))
                                                  (search-forward "\\documentclass" nil t)))))
          (tlw-live--wait (lambda () (with-current-buffer ebuf
                                       (and emacs-collab-mode (emacs-collab-doc-synced (emacs-collab--doc)))))
                          30 "synced")
          (tlw-live--check "buffer synced, mode on" (buffer-local-value 'texlyre-workspace-mode ebuf))
          (with-current-buffer ebuf
            (goto-char (point-max)) (insert "EMACS-MARK\n")
            (tlw-live--wait (lambda () (null (emacs-collab-doc-pending (emacs-collab--doc)))) 30 "ack")
            (tlw-live--check "edit acknowledged by the bridge" t)
            (tlw-live--wait (lambda () (save-excursion (goto-char (point-min))
                                                       (search-forward "BROWSER-MARK" nil t)))
                            30 "browser edit")
            (tlw-live--check "browser edit arrived in the buffer" t)
            (save-buffer))
          (texlyre-quit)
          (tlw-live--check "quit: no sessions/connections"
                           (and (null texlyre-workspace--sessions) (null emacs-collab--connections)))
          (tlw-live--check "quit: unrelated buffer kept" (buffer-live-p unrelated))
          (tlw-live--check "quit: project buffer gone" (null (get-file-buffer main)))))
    (ignore-errors (when texlyre-workspace--sessions (texlyre-quit))))
  (princ (if tlw-live--failed "LIVE: FAIL\n" "LIVE: PASS\n"))
  (kill-emacs (if tlw-live--failed 1 0)))
