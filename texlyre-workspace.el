;;; texlyre-workspace.el --- TeXlyre workspace on emacs-collab  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Joy H.J. Lee
;; Version: 0.1
;; Package-Requires: ((emacs "30.1") (emacs-collab "0.1"))
;; Keywords: tex, collaboration
;; URL: https://example.invalid/texlyre-workspace

;; This file is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at your
;; option) any later version.  It is distributed WITHOUT ANY WARRANTY.

;;; Commentary:

;; The TeXlyre frontend of emacs-collab.  It is thin: the bridge
;; (`TeXlyre_bridge') joins the project through TeXlyre's y-websocket relay
;; and mirrors the text files into a local directory; emacs-collab.el syncs
;; the buffers; the window layout and the quit come from
;; emacs-collab-layout.el.  This file adds what is TeXlyre's own: a list of
;; relays, the project id, the main .tex file and the local latexmk PDF.
;;
;;   M-x texlyre-open-project     pick a relay, give a share link or UUID
;;   M-x texlyre-quit             close it all (also `M-t q' in its buffers)
;;
;; See README.md for the limits (relay mode, read-only tree, no binaries).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-collab)
(require 'emacs-collab-layout)

(defgroup texlyre-workspace nil
  "TeXlyre workspace on emacs-collab."
  :group 'emacs-collab :prefix "texlyre-")

(defcustom texlyre-workspace-relays
  '((:name "TeXlyre (edit me)" :url "wss://YOUR-HOST/yws"))
  "TeXlyre y-websocket relays, as plists.
:name is shown in the picker, :url is the relay's websocket URL.  The
TeXlyre flake serves its relay at /yws on the TeXlyre origin, so this is
usually wss://<host of your TeXlyre>/yws (ws:// without TLS)."
  :type '(repeat plist))

(defcustom texlyre-workspace-bridge-command '("TeXlyre_bridge")
  "The bridge: an argv list, or a string naming the executable."
  :type '(choice (repeat string) string))

(defcustom texlyre-workspace-mirror-directory "~/collab/texlyre/"
  "Where projects are mirrored, as RELAY/UUID below this directory."
  :type 'directory)

(defcustom texlyre-workspace-layout-args '(:tree t :terminal t)
  "Extra `emacs-collab-layout-build' arguments (the PDF pane is always added)."
  :type 'plist)

(defcustom texlyre-workspace-pdf-function #'texlyre-workspace-default-pdf-file
  "Function from the main .tex file to the PDF the local build produces."
  :type 'function)

(defcustom texlyre-workspace-latexmk-command
  '("latexmk" "-pdf" "-interaction=nonstopmode" "-synctex=1")
  "Command used by `texlyre-workspace-compile' when AUCTeX has no LatexMk."
  :type '(repeat string))

(defcustom texlyre-workspace-unsynced-regexp
  (concat "\\(?:\\`\\|/\\)\\(?:build\\|out\\|_minted[^/]*\\)/"
          "\\|\\.\\(?:pdf\\|aux\\|log\\|out\\|toc\\|lof\\|lot\\|fls\\|fdb_latexmk"
          "\\|synctex\\(?:\\.gz\\)?\\|bbl\\|blg\\|bcf\\|run\\.xml\\|nav\\|snm\\|vrb\\)\\'")
  "Project-relative paths that are never attached for syncing.
Local build output and binary files: the PDF the local latexmk writes
into the mirror must not be sent to the bridge as a document."
  :type 'regexp)

(defvar texlyre-workspace-project-history nil
  "History of projects entered.")

;;; Sessions

(cl-defstruct (texlyre-workspace-session (:constructor texlyre-workspace--make-session)
                                         (:copier nil))
  relay project mirror conn main)

(defvar texlyre-workspace--sessions nil
  "Open sessions, newest first.")

(defun texlyre-workspace--session-for-conn (conn)
  (cl-find conn texlyre-workspace--sessions :key #'texlyre-workspace-session-conn))

(defun texlyre-workspace--session-for-file (&optional file)
  (let ((file (or file buffer-file-name default-directory)))
    (and file
         (cl-find-if (lambda (s)
                       (file-in-directory-p (file-truename file)
                                            (texlyre-workspace-session-mirror s)))
                     texlyre-workspace--sessions))))

(defun texlyre-workspace--current-session ()
  (or (texlyre-workspace--session-for-file)
      (car texlyre-workspace--sessions)
      (user-error "No TeXlyre project is open")))

;;; Relays and projects

(defun texlyre-workspace--relay (name)
  "The relay plist called NAME (a string, or already a plist)."
  (if (consp name) name
    (or (cl-find name texlyre-workspace-relays
                 :key (lambda (s) (plist-get s :name)) :test #'equal)
        (user-error "Unknown TeXlyre relay: %s" name))))

(defun texlyre-workspace--read-relay ()
  (cond ((null texlyre-workspace-relays)
         (user-error "Set `texlyre-workspace-relays'"))
        ((null (cdr texlyre-workspace-relays)) (car texlyre-workspace-relays))
        (t (texlyre-workspace--relay
            (completing-read "TeXlyre relay: "
                             (mapcar (lambda (s) (plist-get s :name))
                                     texlyre-workspace-relays)
                             nil t)))))

(defconst texlyre-workspace--uuid-regexp
  "[0-9a-fA-F]\\{8\\}-[0-9a-fA-F]\\{4\\}-[0-9a-fA-F]\\{4\\}-[0-9a-fA-F]\\{4\\}-[0-9a-fA-F]\\{12\\}")

(defun texlyre-workspace-parse-project (string)
  "The project UUID (lower case) in STRING, a share link or a bare UUID."
  (let ((s (string-trim string)))
    (cond ((string-empty-p s) (user-error "No project given"))
          ((string-match (concat "\\`" texlyre-workspace--uuid-regexp "\\'") s)
           (downcase s))
          ((string-match (concat "#yjs:\\(" texlyre-workspace--uuid-regexp "\\)") s)
           (downcase (match-string 1 s)))
          (t (user-error "Not a TeXlyre share link or project UUID: %s" s)))))

(defun texlyre-workspace--slug (s)
  (let ((r (replace-regexp-in-string "[^[:alnum:]._-]+" "-" s)))
    (string-trim r "-+" "-+")))

(defun texlyre-workspace--mirror-dir (relay id)
  (file-name-as-directory
   (expand-file-name (concat (texlyre-workspace--slug (plist-get relay :name)) "/" id)
                     texlyre-workspace-mirror-directory)))

(defun texlyre-workspace--bridge-argv ()
  (let* ((c texlyre-workspace-bridge-command)
         (argv (if (stringp c) (list c) c))
         (exe (car argv)))
    (unless (or (executable-find exe)
                (and (file-name-absolute-p exe) (file-executable-p exe)))
      (user-error "TeXlyre bridge not found: %s (see README.md)" exe))
    (cons (or (executable-find exe) exe) (cdr argv))))

;;; Main file and PDF

(defun texlyre-workspace--documentclass-p (file)
  (with-temp-buffer
    (ignore-errors (insert-file-contents file nil 0 8000))
    (goto-char (point-min))
    (re-search-forward "^[^%\n]*\\\\documentclass" nil t)))

(defun texlyre-workspace-main-file (conn)
  "Absolute path of the main .tex file of CONN's project.
The bridge's `main' if it has a \\documentclass, else the first .tex file
that has one, else the bridge's `main', else the first .tex file."
  (let* ((root (emacs-collab-conn-root conn))
         (project (emacs-collab-conn-project conn))
         (main (alist-get 'main project))
         (tex (cl-remove-if-not (lambda (f) (string-suffix-p ".tex" f))
                                (append (alist-get 'files project) nil)))
         (abs (lambda (f) (expand-file-name f root)))
         (class-p (lambda (f) (and (file-exists-p (funcall abs f))
                                   (texlyre-workspace--documentclass-p (funcall abs f)))))
         (found (if (and main (funcall class-p main)) main (cl-find-if class-p tex)))
         (pick (or found main (car tex))))
    (and pick (funcall abs pick))))

(defvar TeX-output-dir)
(defvar TeX-after-compilation-finished-functions)

(defun texlyre-workspace-default-pdf-file (main)
  "The PDF latexmk builds from MAIN, honouring AUCTeX's `TeX-output-dir'."
  (let* ((buf (get-file-buffer main))
         (out (cond ((and buf (local-variable-p 'TeX-output-dir buf))
                     (buffer-local-value 'TeX-output-dir buf))
                    ((boundp 'TeX-output-dir) (default-value 'TeX-output-dir))))
         (dir (file-name-directory main)))
    (expand-file-name (concat (file-name-base main) ".pdf")
                      (if (stringp out) (expand-file-name out dir) dir))))

;;; Opening

;;;###autoload
(defun texlyre-open-project (&optional relay project)
  "Open a TeXlyre PROJECT through RELAY and build the workspace.
Interactively, pick a relay, then paste a share link or UUID.  The layout
is built once the bridge reports `ready'.  Return the emacs-collab
connection."
  (interactive)
  (let* ((relay (if relay (texlyre-workspace--relay relay) (texlyre-workspace--read-relay)))
         (id (texlyre-workspace-parse-project
              (or project (read-string "TeXlyre share link or project UUID: " nil
                                       'texlyre-workspace-project-history))))
         (mirror (texlyre-workspace--mirror-dir relay id))
         (argv (texlyre-workspace--bridge-argv))
         (params `((relay . ,(plist-get relay :url))
                   (project . ,id)
                   (mirror_dir . ,(directory-file-name mirror)))))
    (when (cl-find (file-truename mirror) texlyre-workspace--sessions
                   :key #'texlyre-workspace-session-mirror :test #'equal)
      (user-error "Already open: %s" mirror))
    (make-directory mirror t)
    (texlyre-workspace--install)
    (let* ((s (texlyre-workspace--make-session :relay relay :project id
                                               :mirror (file-truename mirror)))
           (conn (emacs-collab-connect argv params)))
      (setf (texlyre-workspace-session-conn s) conn)
      (push s texlyre-workspace--sessions)
      conn)))

(defun texlyre-workspace--attach-p (_conn path)
  (not (string-match-p texlyre-workspace-unsynced-regexp path)))

(defun texlyre-workspace--install ()
  (setq emacs-collab-attach-predicate #'texlyre-workspace--attach-p)
  (add-hook 'emacs-collab-ready-functions #'texlyre-workspace--on-ready)
  (add-hook 'find-file-hook #'texlyre-workspace--maybe-enable)
  (add-hook 'TeX-after-compilation-finished-functions #'texlyre-workspace--after-compile))

(defun texlyre-workspace--uninstall ()
  (when (eq emacs-collab-attach-predicate #'texlyre-workspace--attach-p)
    (setq emacs-collab-attach-predicate nil))
  (remove-hook 'emacs-collab-ready-functions #'texlyre-workspace--on-ready)
  (remove-hook 'find-file-hook #'texlyre-workspace--maybe-enable)
  (remove-hook 'TeX-after-compilation-finished-functions #'texlyre-workspace--after-compile))

(defun texlyre-workspace--on-ready (conn)
  (when-let* ((s (texlyre-workspace--session-for-conn conn)))
    (let* ((main (texlyre-workspace-main-file conn))
           (root (emacs-collab-conn-root conn)))
      (setf (texlyre-workspace-session-main s) main)
      (add-to-list 'texlyre-workspace-project-history (texlyre-workspace-session-project s))
      (apply #'emacs-collab-layout-build
             :root root :main-file main :connection conn
             :pdf (and main (lambda () (funcall texlyre-workspace-pdf-function main)))
             :on-quit (lambda (_root) (texlyre-workspace--forget s))
             (cl-loop for (k v) on texlyre-workspace-layout-args by #'cddr
                      unless (memq k '(:root :main-file :connection :pdf :on-quit))
                      append (list k v)))
      (dolist (b (buffer-list))
        (with-current-buffer b (texlyre-workspace--maybe-enable))))))

(defun texlyre-workspace--forget (s)
  (setq texlyre-workspace--sessions (delq s texlyre-workspace--sessions))
  (dolist (b (buffer-list))
    (when (buffer-local-value 'texlyre-workspace-mode b)
      (with-current-buffer b (texlyre-workspace-mode -1))))
  (unless texlyre-workspace--sessions (texlyre-workspace--uninstall)))

;;; Mode and commands

(defvar texlyre-workspace-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-t q") #'texlyre-quit)
    (define-key map (kbd "M-t r") #'texlyre-workspace-resync)
    (define-key map (kbd "M-t s") #'texlyre-workspace-status)
    (define-key map (kbd "M-t c") #'texlyre-workspace-compile)
    map)
  "Keymap of `texlyre-workspace-mode'.")

(define-minor-mode texlyre-workspace-mode
  "Keys for a buffer of an open TeXlyre project.
\\{texlyre-workspace-mode-map}"
  :lighter " TL" :keymap texlyre-workspace-mode-map)

(defun texlyre-workspace--maybe-enable ()
  (when (and buffer-file-name (not texlyre-workspace-mode)
             (texlyre-workspace--session-for-file buffer-file-name))
    (texlyre-workspace-mode 1)))

;;;###autoload
(defun texlyre-quit ()
  "Close the TeXlyre workspace of the current buffer and everything it started."
  (interactive)
  (let ((s (texlyre-workspace--current-session)))
    (emacs-collab-layout-quit (texlyre-workspace-session-mirror s))
    ;; A session whose layout never came up (bridge failed) has no on-quit.
    (when (memq s texlyre-workspace--sessions)
      (when-let* ((c (texlyre-workspace-session-conn s)))
        (when (memq c emacs-collab--connections) (emacs-collab-disconnect c)))
      (texlyre-workspace--forget s))))

(defun texlyre-workspace-resync ()
  "Re-attach the current buffer: fetch its text from the bridge again.
Local edits not yet acknowledged are dropped in favour of the shared text."
  (interactive)
  (let ((s (texlyre-workspace--current-session)))
    (unless (and buffer-file-name (texlyre-workspace--session-for-file buffer-file-name))
      (user-error "This buffer is not in a TeXlyre project"))
    (if-let* ((d (and emacs-collab-mode (emacs-collab--doc))))
        (emacs-collab--reattach (texlyre-workspace-session-conn s) d)
      (setq emacs-collab--conn (texlyre-workspace-session-conn s))
      (emacs-collab-mode 1))
    (message "texlyre: re-attaching %s" (file-name-nondirectory buffer-file-name))))

(defun texlyre-workspace-status ()
  "Show the state of the current project's connection."
  (interactive)
  (let* ((s (texlyre-workspace--current-session))
         (conn (texlyre-workspace-session-conn s)))
    (message "texlyre: %s / %s -- %s%s; mirror %s; %d document(s), %d peer(s)"
             (plist-get (texlyre-workspace-session-relay s) :name)
             (texlyre-workspace-session-project s)
             (emacs-collab-conn-status conn)
             (if-let* ((x (emacs-collab-conn-status-detail conn))) (format " (%s)" x) "")
             (abbreviate-file-name (texlyre-workspace-session-mirror s))
             (hash-table-count (emacs-collab-conn-docs conn))
             (hash-table-count (emacs-collab-conn-peers conn)))))

(defvar TeX-command-list)
(declare-function TeX-command "tex-buf")
(declare-function TeX-master-file "tex")

(defun texlyre-workspace--after-compile (&optional file)
  "Show FILE, a finished PDF, in the project's PDF pane."
  (when (and (stringp file) (string-suffix-p ".pdf" file) (file-exists-p file))
    (when-let* ((s (texlyre-workspace--session-for-file file)))
      (emacs-collab-layout-show-pdf file (texlyre-workspace-session-mirror s)))))

;;;###autoload
(defun texlyre-workspace-compile ()
  "Build the main file locally and show the PDF.
Uses AUCTeX's LatexMk command when it has one, else runs latexmk itself.
Images are not synced; copy any the document needs into the mirror."
  (interactive)
  (let* ((s (texlyre-workspace--current-session))
         (main (or (texlyre-workspace-session-main s) (user-error "No main file")))
         (pdf (funcall texlyre-workspace-pdf-function main)))
    (if (and (fboundp 'TeX-command) (boundp 'TeX-command-list)
             (assoc "LatexMk" TeX-command-list)
             (get-file-buffer main))
        (with-current-buffer (get-file-buffer main)
          (TeX-command "LatexMk" #'TeX-master-file))
      (let* ((default-directory (file-name-directory main))
             (out (file-name-directory pdf))
             (buf (get-buffer-create "*texlyre-latexmk*"))
             (proc (make-process
                    :name "texlyre-latexmk" :buffer buf :noquery t
                    :command (append texlyre-workspace-latexmk-command
                                     (unless (equal out default-directory)
                                       (list (concat "-outdir=" (directory-file-name out))))
                                     (list main))
                    :sentinel (lambda (p _e)
                                (when (and (not (process-live-p p)) (file-exists-p pdf))
                                  (emacs-collab-layout-show-pdf
                                   pdf (texlyre-workspace-session-mirror s)))))))
        (with-current-buffer buf (let ((inhibit-read-only t)) (erase-buffer)))
        (emacs-collab-layout-register-process proc (texlyre-workspace-session-mirror s))
        proc))))

(provide 'texlyre-workspace)
;;; texlyre-workspace.el ends here
