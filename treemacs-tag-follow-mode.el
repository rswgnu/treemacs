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
;; TODO

;;; Code:

(require 'cl-lib)
(require 'imenu)
(require 'f)
(require 'hl-line)
(require 'treemacs-customization)
(require 'treemacs-impl)
(require 'treemacs-tags)
(require 'treemacs-follow-mode)

(defvar treemacs--tag-follow-timer nil
  "The idle timer object for `treemacs-tag-follow-mode'.
Active while tag follow mode is enabled and nil/canceled otherwise.")

(defsubst treemacs--flatten&sort-imenu-index ()
  "Flatten current file's imenu index and sort it by tag position.
The tags are sorted into the order in which they appear, reguardless of section
or nesting depth."
  (let* ((imenu-auto-rescan t)
         (flat-index (-> (buffer-file-name)
                         (treemacs--get-imenu-index)
                         (treemacs--flatten-imenu-index)))
         (semantic? (overlayp (-> flat-index (car) (car) (cdr))))
         (sorted-index (sort
                        flat-index
                        (if semantic?
                            #'treemacs--compare-tag-paths-semantic
                          #'treemacs--compare-tag-paths))))
    ;; go ahead and just transform semantic overlays into markers so we dont
    ;; have trouble with comparisons when searching a position
    (when semantic?
      (dolist (tag-path sorted-index)
        (let ((leaf (car tag-path))
              (marker (make-marker)))
          (setcdr leaf (move-marker marker (overlay-start (cdr leaf)))))))
    sorted-index))

(defun treemacs--flatten-imenu-index (index &optional path)
  "Flatten a nested imenu INDEX to a flat list of tag paths.
The function works recursively with PATH being the already collected tag path in
each iteration.

INDEX: Imenu Tag Index
PATH: String List"
  (declare (pure t) (side-effect-free t))
  (let (result)
    (--each index
     (if (imenu--subalist-p it)
         (setq result
               (append result (treemacs--flatten-imenu-index (cdr it) (cons (car it) path))))
       (setq result (cons (cons it (nreverse (copy-sequence path))) result))))
    result))

(defun treemacs--compare-tag-paths (p1 p2)
  "Compare two tag paths P1 & P2 by the position of the tags they lead to.
Used to sort tag paths according to the order their tags appear in.

P1: Tag-Path
P2: Tag-Path"
  (declare (pure t) (side-effect-free t))
  (< (-> p1 (car) (cdr) (marker-position))
     (-> p2 (car) (cdr) (marker-position))))

(defun treemacs--compare-tag-paths-semantic (p1 p2)
  "Compare two tag paths P1 & P2 by the position of the tags they lead to.
Used to sort tag paths according to the order their tags appear in for buffers
where imenu content is generated with `semantic-mode`, which uses overlays
instead of markers to store tag positions.

P1: Tag-Path
P2: Tag-Path"
  (declare (pure t) (side-effect-free t))
  (< (-> p1 (car) (cdr) (overlay-start))
     (-> p2 (car) (cdr) (overlay-start))))

(defun treemacs--find-index-pos (point list)
  "Find the tag at POINT within a flat tag-path LIST.
Returns the tag-path whose tag is the last to be situated before POINT (meaning
that the next tag is after POINT and thus too far). Accounts for POINT being
located either before the first or after the last tag.

POINT: Int
LIST: (Sorted) Tag Path List"
  (declare (pure t) (side-effect-free t))
  (when list
    (let ((first (car list))
          (last (nth (1- (length list)) list)))
      (cond
       ((<= point (-> first car cdr))
        first)
       ((>= point (-> last car cdr))
        last)
       (t (treemacs--binary-index-search point list))))))

(cl-defun treemacs--binary-index-search (point list &optional (start 0) (end (1- (length list))))
  "Finds the position of POINT in LIST using a binary search.
Continuation of `treemacs--find-index-pos'. Search LIST between START & END.

POINT: Integer
LIST: Sorted Tag Path List
START: Integer
END: Integer"
  (declare (pure t) (side-effect-free t))
  (let* ((index  (+ start (/ (- end start) 2)))
         (elem1  (nth index list))
         (elem2  (nth (1+ index) list))
         (pos1   (-> elem1 car cdr))
         (pos2   (-> elem2 car cdr)))
    (cond
     ((and (> point pos1)
           (<= point pos2))
      elem1)
     ((> pos2 point)
      (treemacs--binary-index-search point list 0 index))
     ((< pos2 point)
      (treemacs--binary-index-search point list index end)))))

(defsubst treemacs--do-follow-tag (flat-index treemacs-window buffer-file)
  "Actual tag-follow implementation, run once the necessary data is gathered.

FLAT-INDEX: Sorted list of tag paths
TREEMACS-WINDOW: Window
BUFFER-FILE: Path"
  (let* ((tag-path (treemacs--find-index-pos (point) flat-index))
         (file-states '(file-node-open file-node-closed))
         (btn))
    (when tag-path
      (with-selected-window treemacs-window
        (setq btn (treemacs--current-button))
        ;; current button might not be there when point is on the header
        (if btn
            (progn
              ;; first move to the nearest file when we're on a tag
              (when (memq (button-get btn 'state) '(tag-node-open tag-node-closed tag-node))
                (while (not (memq (button-get btn 'state) file-states))
                  (setq btn (button-get btn 'parent))))
              ;; when that doesnt work move manually to the correct file
              (unless (string-equal buffer-file (button-get btn 'abs-path))
                (setq btn (treemacs--goto-button-at buffer-file))))
          ;; also move manually when point is on the header
          (setq btn (treemacs--goto-button-at buffer-file)))
        (goto-char (button-start btn))
        (unless (eq 'file-node-closed (button-get btn 'state))
          (treemacs--close-tags-for-file btn))
        ;; imenu already rescanned when fetching the tag path
        (let ((imenu-auto-rescan nil))
          ;; the target tag still has its position marker attached
          (setcar tag-path (car (car tag-path)))
          (treemacs--goto-tag-button-at tag-path buffer-file (button-start btn)))
        (hl-line-highlight)
        (treemacs--evade-image)))))

(defun treemacs--follow-tag-at-point ()
  "Follow the tag at point in the treemacs view."
  (interactive)
  (let* ((treemacs-window (treemacs--is-visible?))
         (buffer (current-buffer))
         (buffer-file (when buffer (buffer-file-name)))
         (root (when treemacs-window (with-selected-window treemacs-window (treemacs--current-root)))))
    (when (and treemacs-window
               buffer-file
               (when root (treemacs--is-path-in-dir? buffer-file root)))
      (-when-let (index (treemacs--flatten&sort-imenu-index))
        (treemacs--do-follow-tag index treemacs-window buffer-file)))))

(defsubst treemacs--setup-tag-follow-mode ()
  "Setup tag follow mode."
  (treemacs-follow-mode -1)
  (setq treemacs--tag-follow-timer
        (run-with-idle-timer treemacs-tag-follow-delay t #'treemacs--follow-tag-at-point)))

(defsubst treemacs--tear-down-tag-follow-mode ()
  "Tear down tag follow mode."
  (cancel-timer treemacs--tag-follow-timer))

(define-minor-mode treemacs-tag-follow-mode
  "Toggle `treemacs-tag-follow-mode'.

This acts as more fine-grained alternative to `treemacs-follow-mode' and will
thus disable `treemacs-follow-mode' on activation. When enabled treemacs will
focus not only the file of the current buffer, but also the tag at point.

The follow action is attached to Emacs' idle timer and will run
`treemacs-tag-follow-delay' seconds of idle time. The delay value is not an
integer, meaning it accepts floating point values like 1.5.

Every time a tag is followed a rescan of the imenu index is forced by
temporarily setting `imenu-auto-rescan' to t. This is necessary to assure that
creation or deletion of tags does not lead to errors and guarantees an always
up-to-date tag view.

Note that in order to move to a tag in treemacs the treemacs buffer's window
needs to be temporarily selected, which will reset `blink-cursor-mode's timer if
it is enabled. This will result in the cursor blinking seemingly pausing for a
short time and giving the appereance of the tag follow action lasting much
longer than it really does."
  :init-value nil
  :global     t
  :lighter    nil
  (if treemacs-tag-follow-mode
      (treemacs--setup-tag-follow-mode)
    (treemacs--tear-down-tag-follow-mode)))

(provide 'treemacs-tag-follow-mode)

;;; treemacs-tag-follow-mode.el ends here
