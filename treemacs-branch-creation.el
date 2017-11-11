;;; treemacs.el --- A tree style file viewer package -*- lexical-binding: t -*-

;; Copyright (C) 2017 Alexander Miller

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;; Code in this file is considered performance critical.
;;; The usual restrictions w.r.t quality, readability and maintainability are
;;; lifted here.

;;; Code:

(require 'cl-lib)
(require 'treemacs-impl)
(require 'treemacs-visuals)
(require 'treemacs-async)
(require 'treemacs-customization)

(declare-function treemacs--start-watching "treemacs-filewatch-mode")

(defsubst treemacs--button-at (pos)
  "Return the button at position POS in the current buffer, or nil.
If the button at POS is a text property button, the return value
is a marker pointing to POS."
  (copy-marker pos t))

(defsubst treemacs--sort-alphabetic-asc (f1 f2)
  "Sort F1 and F2 alphabetically asc."
  (string-lessp f2 f1))

(defsubst treemacs--sort-alphabetic-desc (f1 f2)
  "Sort F1 and F2 alphabetically desc."
  (string-lessp f1 f2))

(defsubst treemacs--sort-size-asc (f1 f2)
  "Sort F1 and F2 by size asc."
  (>= (nth 7 (file-attributes f1))
      (nth 7 (file-attributes f2))))

(defsubst treemacs--sort-size-desc (f1 f2)
  "Sort F1 and F2 by size desc."
  (< (nth 7 (file-attributes f1))
     (nth 7 (file-attributes f2))))

(defsubst treemacs--sort-mod-time-asc (f1 f2)
  "Sort F1 and F2 by modification time asc."
  (file-newer-than-file-p f1 f2))

(defsubst treemacs--sort-mod-time-desc (f1 f2)
  "Sort F1 and F2 by modification time desc."
  (file-newer-than-file-p f2 f1))

(defsubst treemacs--insert-button (label &rest properties)
  "Insert a button with LABEL and given PROPERTIES."
  (let ((beg (point)))
    (insert label)
    (add-text-properties beg (point) (append '(button (t) category default-button) properties))
    beg))

(defsubst treemacs--get-dir-content (dir)
  "Get the content of DIR, separated into sublists of first dirs, then files."
  (let* ((sort-func
          (pcase treemacs-sorting
            (`alphabetic-asc  #'treemacs--sort-alphabetic-asc)
            (`alphabetic-desc #'treemacs--sort-alphabetic-desc)
            (`size-asc        #'treemacs--sort-size-asc)
            (`size-desc       #'treemacs--sort-size-desc)
            (`mod-time-asc    #'treemacs--sort-mod-time-asc)
            (`mod-time-desc   #'treemacs--sort-mod-time-desc)
            (_                (error "[Treemacs] Unknown treemacs-sorting value '%s'" treemacs-sorting))))
         (entries (-> dir (directory-files t nil t) (treemacs--filter-files-to-be-shown)))
         (dirs-files (-separate #'file-directory-p entries)))
    (list (sort (cl-first dirs-files) sort-func)
          (sort (cl-second dirs-files) sort-func))))

(defsubst treemacs--insert-dir-node (path prefix parent depth)
  "Return the text to insert for a directory node for PATH.
PREFIX is a string inserted as indentation.
PARENT is the (optional) button under which this one is inserted.
DEPTH indicates how deep in the filetree the current button is."
  ;; for directories the icon is included in the prefix since it's always known
  (list
   prefix
   (propertize (f-filename path)
               'button '(t)
               'category 'default-button
               'state 'dir-node-closed
               'abs-path path
               'parent parent
               'depth depth
               'face 'treemacs-directory-face)))

(defsubst treemacs--insert-file-node (path prefix parent depth git-info)
  "Return the text to insert for a file node for PATH.
PREFIX is a string inserted as indentation.
PARENT is the (optional) button under which this one is inserted.
DEPTH indicates how deep in the filetree the current button is.
GIT-INFO (if any) is used to determine the node's face."
  (list
   prefix
   (with-no-warnings
     (gethash (-> path (treemacs--file-extension) (downcase))
              treemacs-icons-hash
              treemacs-icon-fallback))
   (propertize (f-filename path)
               'button '(t)
               'category 'default-button
               'state 'file-node-closed
               'abs-path path
               'parent parent
               'depth depth
               'face (if treemacs-git-integration
                         (treemacs--get-face path git-info)
                       'treemacs-file-face))))

(cl-defmacro treemacs--button-open (&key button new-state new-icon open-action post-open-action)
  "Open BUTTON.
Give it NEW-STATE, and, optionally, NEW-ICON. Perform first OPEN-ACTION and,
optionally, POST-OPEN-ACTION."
  `(treemacs--with-writable-buffer
    (button-put ,button 'state ,new-state)
    (beginning-of-line)
    ,@(when new-icon
      `((treemacs--node-symbol-switch ,new-icon)))
    ,open-action
    ,post-open-action))

(cl-defmacro treemacs--create-buttons (&key nodes depth extra-vars node-action node-name)
  "Building block macro for creating buttons from a list of items.
NODES is the list to create buttons from.
DEPTH is the indentation level buttons will be created on.
EXTRA-VARS are additional var bindings inserted into the initial let block.
NODE-ACTION is the button creating form inserted for every NODE.
NODE-NAME is the variable individual nodes are bound to in NODE-ACTION."
  `(let* ((depth ,depth)
          (prefix (concat "\n" (make-string (* depth treemacs-indentation) ?\ )))
          (,node-name (cl-first ,nodes))
          (strings)
          ,@extra-vars)
     (when ,node-name
       (dolist (,node-name ,nodes)
         (--each ,node-action
           (push it strings))))
     (end-of-line)
     (insert (apply #'concat (nreverse strings)))))

(defsubst treemacs--collapse-dirs (dirs root)
  "Display DIRS as collpased under ROOT.
Go to each dir button, expand its label with the collpased dirs, set its new
path and give it a special parent-path property so opening it will add the
correct cache entries."
  (when dirs
    (let ((search-start (if (string= root (treemacs--current-root))
                            0
                          (button-start (treemacs--goto-button-at root)))))
      (--each dirs
        ;; no warning since filewatch mode is known to be defined
        (when (with-no-warnings treemacs-filewatch-mode)
          (treemacs--start-watching (car it))
          (dolist (step (nthcdr 2 it))
            (treemacs--start-watching step t)))
        (let* ((b (treemacs--goto-button-at (car it) search-start))
               (props (text-properties-at (button-start b))))
          (button-put b 'abs-path (nth (- (length it) 1) it))
          (button-put b 'parent-path root)
          (end-of-line)
          (let ((beg (point)))
            (insert (cadr it))
            (add-text-properties beg (point) props)))))))

(defun treemacs--create-branch (root depth git-process collapse-process &optional parent)
  "Create a new treemacs branch under ROOT.
The branch is indented at DEPTH and uses the eventual outputs of
GIT-PROCESS to decide on file nodes' faces and COLLAPSE-PROCESS to determine
which directories should be displayed as one. The nodes' parent property is set
to PARENT."
  (save-excursion
    (let* ((dirs-and-files (treemacs--get-dir-content root))
           (dirs (cl-first dirs-and-files))
           (files (cl-second dirs-and-files))
           (git-info))
      (treemacs--create-buttons
       :nodes dirs
       :extra-vars ((dir-prefix (concat prefix (with-no-warnings treemacs-icon-closed))))
       :depth depth
       :node-name node
       :node-action (treemacs--insert-dir-node node dir-prefix parent depth))
      (setq git-info (treemacs--parse-git-status git-process))
      (treemacs--create-buttons
       :nodes files
       :depth depth
       :node-name node
       :node-action (treemacs--insert-file-node node prefix parent depth git-info))
      (treemacs--collapse-dirs (treemacs--parse-collapsed-dirs collapse-process) root))
    ;; reopen here only since create-branch is called both when opening a node and
    ;; building the entire tree
    (treemacs--reopen-at root)))

(cl-defmacro treemacs--button-close (&key button new-state new-icon post-close-action)
  "Close node given by BTN, use NEW-ICON and set state of BTN to NEW-STATE."
  `(treemacs--with-writable-buffer
    ,@(when new-icon
        `((treemacs--node-symbol-switch ,new-icon)))
    (end-of-line)
    (forward-button 1)
    (beginning-of-line)
    (let* ((pos-start (point))
           (next (treemacs--next-non-child-node ,button))
           (pos-end (if next (-> next (button-start) (previous-button) (button-end) (1+)) (point-max))))
      (button-put ,button 'state ,new-state)
      (delete-region pos-start pos-end)
      (delete-trailing-whitespace))
    ,post-close-action))

(defun treemacs--check-window-system ()
  "Check if this treemacs instance is running in a GUI or TUI.
If it's running in a TUI use terminal switch to simple text icons."
  (unless (or treemacs-no-images (window-system))
    (with-no-warnings
      (setq-local treemacs-icon-open treemacs-icon-open-text)
      (setq-local treemacs-icon-closed treemacs-icon-closed-text)
      (setq-local treemacs-icon-fallback "")
      (setq-local treemacs-icons-hash (make-hash-table :test #'eq)))))

(provide 'treemacs-branch-creation)

;;; treemacs-branch-creation.el ends here
