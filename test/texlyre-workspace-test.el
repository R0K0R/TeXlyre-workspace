;;; texlyre-workspace-test.el --- Tests  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'texlyre-workspace)

(defvar TeX-output-dir)

(defconst tlw-test--here (file-name-directory (or load-file-name buffer-file-name)))
(defconst tlw-test--bridge
  (or (getenv "TEXLYRE_BRIDGE")
      (expand-file-name "~/git_shit/TeXlyre_bridge/target/debug/TeXlyre_bridge")))
(defconst tlw-test--uuid "3f2a9c1e-5b7d-4e8a-9c2f-0a1b2c3d4e5f")

(defun tlw-test--tmp ()
  (make-temp-file (expand-file-name "tlw-" (or (getenv "EMACS_COLLAB_TEST_TMPDIR")
                                               temporary-file-directory))
                  t))

(defun tlw-test--wait (pred &optional timeout)
  (let ((deadline (+ (float-time) (or timeout 15))) r)
    (while (and (not (setq r (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (or r (ert-fail (list "timeout waiting for" pred)))))

;;; Pure

(ert-deftest tlw-test-parse-project ()
  (let ((id tlw-test--uuid))
    (should (equal (texlyre-workspace-parse-project id) id))
    (should (equal (texlyre-workspace-parse-project (upcase id)) id))
    (should (equal (texlyre-workspace-parse-project
                    (format " https://t.example/texlyre/#yjs:%s&doc:abc " id))
                   id))
    (should-error (texlyre-workspace-parse-project "My Thesis") :type 'user-error)
    (should-error (texlyre-workspace-parse-project "https://t.example/#doc:x") :type 'user-error)
    (should-error (texlyre-workspace-parse-project " ") :type 'user-error)))

(ert-deftest tlw-test-mirror-dir ()
  (let ((texlyre-workspace-mirror-directory "/m/"))
    (should (equal (texlyre-workspace--mirror-dir '(:name "My relay (x)") "abc")
                   "/m/My-relay-x/abc/"))))

(ert-deftest tlw-test-relay-lookup ()
  (let ((texlyre-workspace-relays '((:name "A" :url "ws://a/yws") (:name "B" :url "ws://b/yws"))))
    (should (equal (plist-get (texlyre-workspace--relay "B") :url) "ws://b/yws"))
    (should-error (texlyre-workspace--relay "C") :type 'user-error)
    (should (equal (plist-get (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "A")))
                                (texlyre-workspace--read-relay))
                              :name)
                   "A")))
  (let ((texlyre-workspace-relays '((:name "Only" :url "ws://o/yws"))))
    (should (equal (plist-get (texlyre-workspace--read-relay) :name) "Only")))
  (let ((texlyre-workspace-relays nil))
    (should-error (texlyre-workspace--read-relay) :type 'user-error)))

(ert-deftest tlw-test-bridge-argv ()
  (let ((texlyre-workspace-bridge-command "/definitely/not/here"))
    (should-error (texlyre-workspace--bridge-argv) :type 'user-error))
  (let ((texlyre-workspace-bridge-command '("sh" "-c")))
    (should (equal (cdr (texlyre-workspace--bridge-argv)) '("-c")))))

(ert-deftest tlw-test-attach-predicate ()
  (should (texlyre-workspace--attach-p nil "main.tex"))
  (should (texlyre-workspace--attach-p nil "sec/intro.tex"))
  (should (texlyre-workspace--attach-p nil "refs.bib"))
  (should-not (texlyre-workspace--attach-p nil "build/main.pdf"))
  (should-not (texlyre-workspace--attach-p nil "build/main.aux"))
  (should-not (texlyre-workspace--attach-p nil "main.pdf"))
  (should-not (texlyre-workspace--attach-p nil "main.synctex.gz")))

(ert-deftest tlw-test-pdf-file ()
  (let ((TeX-output-dir "build"))
    (should (equal (texlyre-workspace-default-pdf-file "/p/main.tex") "/p/build/main.pdf")))
  (let ((TeX-output-dir nil))
    (should (equal (texlyre-workspace-default-pdf-file "/p/sub/m.tex") "/p/sub/m.pdf"))))

(ert-deftest tlw-test-main-file ()
  (let* ((dir (file-name-as-directory (tlw-test--tmp)))
         (conn (emacs-collab--make-conn)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a.tex" dir) (insert "% \\documentclass{x}\n\\input{b}\n"))
          (with-temp-file (expand-file-name "b.tex" dir) (insert "\\documentclass{article}\n"))
          (with-temp-file (expand-file-name "c.tex" dir) (insert "text\n"))
          (setf (emacs-collab-conn-root conn) dir
                (emacs-collab-conn-project conn)
                `((main . "c.tex") (files . ["a.tex" "b.tex" "c.tex"])))
          (should (equal (texlyre-workspace-main-file conn) (expand-file-name "b.tex" dir)))
          (setf (emacs-collab-conn-project conn) `((main . "b.tex") (files . ["a.tex" "b.tex"])))
          (should (equal (texlyre-workspace-main-file conn) (expand-file-name "b.tex" dir)))
          (setf (emacs-collab-conn-project conn) `((main . "c.tex") (files . ["c.tex"])))
          (should (equal (texlyre-workspace-main-file conn) (expand-file-name "c.tex" dir)))
          (setf (emacs-collab-conn-project conn) `((files . ["c.tex"])))
          (should (equal (texlyre-workspace-main-file conn) (expand-file-name "c.tex" dir)))
          (setf (emacs-collab-conn-project conn) `((files . [])))
          (should-not (texlyre-workspace-main-file conn)))
      (delete-directory dir t))))

;;; With the bridge (TeXlyre_bridge --test behind test/shim.py)

(defmacro tlw-test--with-open (log &rest body)
  "Run BODY with LOG bound to the shim's log file and everything sandboxed."
  (declare (indent 1))
  `(let* ((base (tlw-test--tmp))
          (texlyre-workspace-mirror-directory (expand-file-name "mirror/" base))
          (texlyre-workspace--sessions nil)
          (emacs-collab--connections nil)
          (emacs-collab-layout-state-file (expand-file-name "layout.eld" base))
          (emacs-collab-layout--sizes nil) (emacs-collab-layout--sizes-loaded nil)
          (emacs-collab-layout--projects nil) (emacs-collab-layout-register-lsp nil)
          (texlyre-workspace-project-history nil)
          (,log (expand-file-name "log" base))
          (process-environment
           (append (list (concat "TEXLYRE_BRIDGE=" tlw-test--bridge)
                         (concat "SHIM_LOG=" ,log))
                   process-environment))
          (texlyre-workspace-bridge-command
           (list "python3" (expand-file-name "shim.py" tlw-test--here)))
          (texlyre-workspace-relays '((:name "T" :url "ws://t.example:1/yws")))
          (unrelated (generate-new-buffer "*unrelated*")))
     (unwind-protect
         (save-window-excursion ,@body)
       (ignore-errors (when texlyre-workspace--sessions (texlyre-quit)))
       (dolist (b (buffer-list))
         (when-let* ((f (buffer-file-name b)))
           (when (string-prefix-p base (file-truename f))
             (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))))
       (kill-buffer unrelated)
       (delete-directory base t))))

(defun tlw-test--seed-mirror (id)
  "Create the mirror dir content the bridge will serve."
  (let ((d (texlyre-workspace--mirror-dir '(:name "T") id)))
    (make-directory d t)
    (with-temp-file (expand-file-name "main.tex" d)
      (insert "\\documentclass{article}\n\\begin{document}\nhello\n\\end{document}\n"))
    (with-temp-file (expand-file-name "refs.bib" d) (insert "@misc{a}\n"))
    d))

(ert-deftest tlw-test-open-layout-quit ()
  (skip-unless (file-executable-p tlw-test--bridge))
  (tlw-test--with-open log
    (let* ((id tlw-test--uuid)
           (m (tlw-test--seed-mirror id))
           (conn (texlyre-open-project "T" (format "https://x.example/#yjs:%s&doc:abc" id))))
      (tlw-test--wait (lambda () (emacs-collab-layout-project m)))
      (let ((p (emacs-collab-layout-project m)))
        (should (eq (emacs-collab-layout-project-conn p) conn))
        (should (emacs-collab-layout-window 'tree))
        (should (emacs-collab-layout-window 'editor))
        (should (emacs-collab-layout-window 'terminal))
        (should (emacs-collab-layout-window 'pdf))
        (should (equal (buffer-file-name (window-buffer (emacs-collab-layout-window 'editor)))
                       (expand-file-name "main.tex" (file-truename m)))))
      (let ((ebuf (window-buffer (emacs-collab-layout-window 'editor))))
        (tlw-test--wait (lambda () (with-current-buffer ebuf
                                     (and emacs-collab-mode (emacs-collab-doc-synced (emacs-collab--doc))))))
        (with-current-buffer ebuf
          (should texlyre-workspace-mode)
          (dolist (k '(("M-t q" . texlyre-quit) ("M-t s" . texlyre-workspace-status)
                       ("M-t c" . texlyre-workspace-compile) ("M-t r" . texlyre-workspace-resync)))
            (should (eq (key-binding (kbd (car k))) (cdr k))))
          (texlyre-workspace-status)
          (texlyre-workspace-resync)
          (tlw-test--wait (lambda () (emacs-collab-doc-synced (emacs-collab--doc))))))
      ;; The attach predicate keeps build output out of sync.
      (should-not (funcall emacs-collab-attach-predicate conn "build/main.pdf"))
      ;; The bridge saw the relay, the bare UUID and the mirror dir.
      (let ((p (alist-get 'params
                          (json-parse-string (car (split-string (with-temp-buffer
                                                                  (insert-file-contents log)
                                                                  (buffer-string))
                                                                "\n" t))
                                             :object-type 'alist))))
        (should (equal (alist-get 'relay p) "ws://t.example:1/yws"))
        (should (equal (alist-get 'project p) id))
        (should (equal (alist-get 'mirror_dir p) (directory-file-name m))))
      (texlyre-quit)
      (should-not texlyre-workspace--sessions)
      (should-not emacs-collab--connections)
      (should-not (emacs-collab-layout-project m))
      (should-not emacs-collab-attach-predicate)
      (should (buffer-live-p unrelated))
      (should (= 1 (length (window-list nil 'no-minibuf)))))))

(ert-deftest tlw-test-already-open ()
  (skip-unless (file-executable-p tlw-test--bridge))
  (tlw-test--with-open log
    (let ((m (tlw-test--seed-mirror tlw-test--uuid)))
      (texlyre-open-project "T" tlw-test--uuid)
      (tlw-test--wait (lambda () (emacs-collab-layout-project m)))
      (should-error (texlyre-open-project "T" tlw-test--uuid) :type 'user-error)
      (texlyre-quit))))

(ert-deftest tlw-test-compile-latexmk-shows-pdf ()
  (skip-unless (and (executable-find "latexmk") (file-executable-p tlw-test--bridge)))
  (tlw-test--with-open log
    (let ((m (tlw-test--seed-mirror tlw-test--uuid)) (TeX-output-dir "build"))
      (texlyre-open-project "T" tlw-test--uuid)
      (tlw-test--wait (lambda () (emacs-collab-layout-project m)))
      (with-current-buffer (window-buffer (emacs-collab-layout-window 'editor))
        (let ((proc (texlyre-workspace-compile)))
          (tlw-test--wait (lambda () (not (process-live-p proc))) 90)))
      (let ((pdf (expand-file-name "build/main.pdf" m)))
        (should (file-exists-p pdf))
        (tlw-test--wait (lambda () (equal (buffer-file-name
                                           (window-buffer (emacs-collab-layout-window 'pdf)))
                                          (file-truename pdf))))))))

(provide 'texlyre-workspace-test)
;;; texlyre-workspace-test.el ends here
