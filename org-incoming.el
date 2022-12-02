;;; org-incoming.el --- Sort incoming PDFs into your org files         -*- coding: utf-8; lexical-binding: t; -*-

;; Copyright (C) 2022 Lukas Barth

;; Author: Lukas Barth <mail@tinloaf.de>
;; Version: 0.1
;; Package-Requires: ((emacs "24.4") (dash "2.19.1") (datetime "0.7.2") (s "1.13.1"))
;; Keywords: files
;; URL: https://github.com/tinloaf/org-incoming

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; This is `org-incoming`, a package to ingest PDF files into your `org` or
;; `org-roam` files.

;; This package is intended to help you if you have a large number of "incoming"
;; PDF files, for example scanned handwritten notes, and you want to somehow
;; capture these PDFs in your org files.  "Capturing" here can mean anything
;; from completely transcribing them (or taking OCRed text in the PDF) to just
;; creating an org file with a title, a date and maybe some tags, which links to
;; the archived PDF.

;;; Code:

(require 'widget)
(require 'dash)
(require 'datetime)
(require 's)

(defvar org-incoming--has-roam "" nil)
(when (require 'org-roam nil 'noerror)
	(setq org-incoming--has-roam 't))

;; TODO check if all of these are necessary
(defvar org-incoming--pdf-buf "" nil)
(defvar org-incoming--pdf-win "" nil)
(defvar org-incoming--query-buf "" nil)
(defvar org-incoming--query-win "" nil)
(defvar org-incoming--org-buf "" nil)
(defvar org-incoming--org-win "" nil)
(defvar org-incoming--cur-extracted "" nil)
(defvar org-incoming--w-name "" nil)
(defvar org-incoming--w-date "" nil)

(defvar org-incoming--cur-source "" nil)
;; Phases are: 'inactive -> 'loaded -> 'named -> 'annotated -> 'stored
;; There's a special phase 'skipped which indicates that processing for the
;; current item was cancelled and the next one should be loaded
(defvar org-incoming--cur-phase "" 'inactive)
(defvar org-incoming--cur-tempdir "" nil)
(defvar org-incoming--cur-annotation-target "" nil)
(defvar org-incoming--cur-annotation-file "" nil)
(defvar org-incoming--cur-pdf-target "" nil)
(defvar org-incoming--cur-targetdir "" nil)
(defvar org-incoming--cur-targetdir-pdf "" nil)
(defvar org-incoming--cur-plist "" nil)
(defvar org-incoming--skipped '() nil)

(defcustom org-incoming-annotation-template "
#+TITLE: ${title}
#+DATE: ${date}

Link: [[${link}]]

* Extracted Text

${extracted}
"
	"Template for creating annotation files.

This will be filled using s.el's s-format, so see the documentation for details.
The available fields are:

${title} - The title assigned during query
${date} - The date assigned during query
${link} - The link to the PDF file (after moving)
${extracted} - Any text extracted from the PDF file"
	:group 'org-incoming
	:type '(string))

(defcustom org-incoming-parse-date-pattern nil
	"Pattern that is used to extract a date from the files filenames.

This is applied to the part of the filename that was
matched by the first sub-expression of
org-incoming-parse-date-re.  This uses the 'Java' (or 'ICU')
format syntax as specified by the datetime package.  See here for
documentation: https://github.com/doublep/datetime/

This can be overridden per folder pair.  Add \":parse-date-pattern
<pattern>\" to the folder pair plist."
	:group 'org-incoming
	:type '(string))

(defcustom org-incoming-parse-date-re "\\(.*\\)"
	"A regular expression applied to the filename before \
org-incoming-parse-date-pattern is applied.

Only the part matched by the first parenthesised sub-expression
in this regular expression is parsed via
org-incoming-parse-date-pattern.  Matching is done using
'string-match', see its documentation for regex syntax.


This can be overridden per folder pair.  Add \":parse-date-re <regex>\" to
the folder pair plist."
	:group 'org-incoming
	:type '(regexp))

(defcustom org-incoming-dirs nil
	"A list of plists describing the source/target pairs and any \
settings overrides for them.

Each plist must at least contain \":source <from-directory>\" and
\":target <to-directory>\".  For each such pair, from-directory
is treated as a path to a directory that contains incoming PDF
files, and to-directory is the target directory.  org-incoming
will place its annotation files in the to-directory, and move the
PDF files into the org-incoming-pdf-subdir directory inside the
to-directory.

Additionally, the plist for each folder pair can contain
overrides for almost all of org-incoming's settings, in the form
of \":<setting-name> <value>\".  See the respective settings for
details."
	:group 'org-incoming
	:type '(repeat (plist)))

(defcustom org-incoming-pdf-subdir "pdfs"
	"Name of the directory inside the to-directory (see \
org-incoming-dirs documentation) into which PDF files should be \
moved.

This can be overridden per folder pair.  Add \":pdf-subdir <setting>\" to
the folder pair plist."
	:group 'org-incoming
	:type '(string))
(defcustom org-incoming-use-roam nil
	"Set to non-nil to create org-roam files instead of plain org \
files as annotations.  This requires org-roam to be installed.

This can be overridden per folder pair.  Add \":use-roam <setting>\" to
the folder pair plist."
	:group 'org-incoming
	:type '(boolean))

;;
;; Start of date widget
;;
(defun org-incoming--datewidget--select (widget &optional _event)
	"Function called when selecting a new date.

Opens a calenderbelow the current window, using org-read-date.  Pass the
actual widget as WIDGET."
	(split-window-below -8)
	(let ((date (org-read-date)))
		(widget-value-set widget date))
	(org-incoming--windows-for-query))


(defun org-incoming--datewidget--validate (widget)
	"Function to validate a datewidget.

Pass the widget as WIDGET.  Returns nil as success and calls 'widget-put
:error' on error."
	(-let (((_sec _min _hour day mon year _dow _dst _tz)
					(parse-time-string (widget-value widget))))
		(if (not (or (eq year nil)
								 (eq mon nil)
								 (eq day nil)))
				nil ;; This is 'success'
			;; Else: Set the error message
			(widget-put widget :error "Invalid date")
			widget)))

(define-widget 'org-incoming--datewidget 'editable-field
	"The date widget used during the query phase of org-incoming."
	:action 'org-incoming--datewidget--select
	;;	:validate 'org-incoming--datewidget--validate
	:size 10)
;;
;; end of date widget
;;

(defun org-incoming--get-setting (setting-name)
	"Return the currently valid setting specified by SETTING-NAME.

This can either come from the variable org-incoming-SETTING-NAME or from
a :SETTING-NAME in the current folder pair plist."
	(let ((variable-name (format "org-incoming-%s" setting-name))
				(plist-symbol-name (format ":%s" setting-name)))
		(if (and (not (eq org-incoming--cur-plist nil))
						 (plist-get org-incoming--cur-plist (intern plist-symbol-name)))
				;; Symbol is in plist: use that value
				(plist-get org-incoming--cur-plist (intern plist-symbol-name))
			;; Else: use value of variable
			(symbol-value (intern variable-name)))))

(defun org-incoming--sanitize-filename (fname)
	"Return a sanitized version of FNAME  that does not contain any \
problematic characters."
	(replace-regexp-in-string "[#<>$+%/\\!`&'|{}?\"=:]" "_" fname))

(defun org-incoming--cleanup-tempdir (&optional force)
	"Clean up the temporary directory created for by org-incoming--new-tempdir.

Set FORCE to non-nil to clean up the directory even if it still
contains files."
	(when (and (not (eq org-incoming--cur-tempdir nil))
						 (file-directory-p org-incoming--cur-tempdir))
		(message (format "Deleting %s" org-incoming--cur-tempdir))
		;; The temp directory should be empty at this point.  By default, don't
		;; specify 'recursive' to avoid accidentially deleting too much.
		(delete-directory org-incoming--cur-tempdir force)))

(defun org-incoming--permissive-rename-file (source dest)
	"Move a file like 'rename-file', but handle the error that \
permissions cannot be set at the target.

Moves SOURCE to DEST.  In the case permissions cannot be set, the file is
moved without permissions being transferred."
	(defun org-incoming--handle-file-error (errvar)
		(let ((errsym (car errvar))
					(errdata (cdr errvar)))
			;; Make sure the error we're handling is really a 'copying permissions'
			;; error.  If not, rethrow
			(when (not (and (string-equal (nth 0 errdata) "Copying permissions to")
									    (string-equal(nth 1 errdata) "Operation not permitted")))
				(signal errsym errdata))
			;; Make sure that the file actually arrived at its destination, otherwise
			;; deleting the source would cause data loss.
			;;
			;; Note that we don't check here that source and dest are identical files
			;; now.  Since we called rename-file without OK-IF-ALREADY-EXISTS, it
			;; would have thrown a (different) error if the destination had already
			;; existed.  Thus, if it exists now, we may assume that it's a copy of
			;; source.
			;;
			;; Yes, in the worst case this could race with something else creating
			;; dest, but that's a user error.
			(when (not (file-exists-p dest))
				(signal errsym errdata))
			;; If the file exists at the destination, complete the 'move' by deleting
			;; the source.
			(when (file-exists-p source)
				(delete-file source))))

	(condition-case errvar
			(rename-file source dest)
		(file-error (org-incoming--handle-file-error errvar))))


(defun org-incoming--new-tempdir ()
	"Create a new temporary directory."
	(org-incoming--cleanup-tempdir)
	(setq org-incoming--cur-tempdir (make-temp-file "org-incoming" 't)))

(defun org-incoming-complete ()
	"Complete the current phase."
	(interactive)
	(cond ((eq org-incoming--cur-phase 'loaded) (org-incoming--handle-form))
				((eq org-incoming--cur-phase 'annotated) (org-incoming--store))
				(t (error "Current state not allowed for org-incoming-complete"))))

(defun org-incoming-skip ()
	"Skip the incoming file currently being processed.

The file is skipped for the current org-incoming session.  If you quit
org-incoming and cal org-incoming-start again, the file will be
processed again."
	(interactive)
	(when (not (or (eq org-incoming--cur-phase 'loaded)
								 (eq org-incoming--cur-phase 'named)))
		(error "Current state not allowed for org-incoming--skip"))

	(when (window-live-p org-incoming--query-win)
		(set-window-dedicated-p org-incoming--query-win nil))
	(when (buffer-live-p org-incoming--query-buf)
		(kill-buffer org-incoming--query-buf))
	(when (buffer-live-p org-incoming--pdf-buf)
		(kill-buffer org-incoming--pdf-buf))
	(when (buffer-live-p org-incoming--org-buf)
		(kill-buffer org-incoming--org-buf))

	(when (eq org-incoming--cur-phase 'named)
		(org-incoming--cleanup-tempdir 't))

	(add-to-list 'org-incoming--skipped org-incoming--cur-source)
	(setq org-incoming--cur-phase 'skipped)

	(org-incoming--next))

(defun org-incoming-quit ()
	"Quit org-incoming.

All inputs for the file currently being processed will be
discarded and the file will not be moved."
	(interactive)

	(setq org-incoming--cur-phase 'inactive)

	(when (window-live-p org-incoming--query-win)
		(set-window-dedicated-p org-incoming--query-win nil))
	(when (buffer-live-p org-incoming--query-buf)
		(kill-buffer org-incoming--query-buf))
	(when (buffer-live-p org-incoming--pdf-buf)
		(kill-buffer org-incoming--pdf-buf))
	(when (buffer-live-p org-incoming--org-buf)
		(kill-buffer org-incoming--org-buf))

	(org-incoming--cleanup-tempdir 't))

(define-minor-mode org-incoming-pdf-mode
	"Mode active in the PDF buffer of org-incoming.

Should not be set manually."
	:init-value
	nil
	:lighter
	" RS-P"
	:keymap
	'(([q] . org-incoming-quit)))

(defvar org-incoming-query-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") 'org-incoming-complete)
    (define-key map (kbd "C-c C-k") 'org-incoming-quit)
		(define-key map (kbd "C-c C-s") 'org-incoming-skip)
    map))

(define-minor-mode org-incoming-query-mode ""
	:init-value
	nil
	:lighter
	" RS-Q")

(defvar org-incoming-org-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") 'org-incoming-complete)
    (define-key map (kbd "C-c C-k") 'org-incoming-quit)
		(define-key map (kbd "C-c C-s") 'org-incoming-skip)
    map))
(define-minor-mode org-incoming-org-mode
	"Mode active in the annotation buffer of org-incoming.
Should not be set manually."
	:init-value
	nil
	:lighter
	" RS-O")

(defun org-incoming--validate-form ()
	"Validate the form of the query phase."
	(when (not (eq org-incoming--cur-phase 'loaded))
		(error "Current state not allowed for org-incoming--validate-form"))
	(let ((title-err (widget-apply org-incoming--w-name :validate))
				(date-err (widget-apply org-incoming--w-date :validate))
				(errmsg nil)
				(form-invalid nil))
		(when (not (eq title-err nil))
			(message (widget-get title-err :error))
			(setq errmsg (widget-get title-err :error))
			(setq form-invalid 't))
		(when (not (eq date-err nil))
			(message (widget-get date-err :error))
			(setq errmsg (widget-get date-err :error))
			(setq form-invalid 't))

		(when form-invalid
			(set-buffer org-incoming--query-buf)
			(goto-char (point-max))
			(widget-insert (format "%s\n" errmsg)))

		form-invalid))

(defun org-incoming--guess-date (fname)
	"Guess a date from the filename FNAME.

This uses the 'parse-date-pattern' and 'parse-date-re' settings."
	(catch 'myexit
		(when (or (eq nil org-incoming-parse-date-pattern)
							(eq nil org-incoming-parse-date-re))
			(throw 'myexit ""))

		(condition-case
				_errvar
				(progn
					(let* ((pattern (org-incoming--get-setting "parse-date-pattern"))
								 (rexp (org-incoming--get-setting "parse-date-re"))
								 (regexed-fname-pos (string-match rexp fname))
								 (regexed-fname (match-string 1 fname)))
						(when (eq regexed-fname nil)
							(throw 'myexit "parsing failed"))
						(let*
								((parser (datetime-parser-to-float 'java pattern
																									 :timezone 'system))
								 (formatter (datetime-float-formatter 'java "yyyy-MM-dd"
																											:timezone 'system))
								 (timepoint (funcall parser regexed-fname))
								 (formatted-date (funcall formatter timepoint)))
							formatted-date)))
			(datetime-invalid-string (progn
																 (message "Date string could not be parsed")
																 ""))))) ;; Return the empty string - this will
																				 ;; be used as 'guessed date'!


(defun org-incoming--init-form (filename)
	"Initialize the form during the query phase.

This initializes the form for the PDF file at FILENAME."
	(let ((inhibit-read-only t)
				(guessed-date (org-incoming--guess-date filename)))
		(when (or (not (boundp 'org-incoming--query-buf))
							(not (buffer-live-p org-incoming--query-buf)))
			(setq org-incoming--query-buf (get-buffer-create "*org-incoming-query*")))
		(set-buffer org-incoming--query-buf)
		(org-incoming-query-mode)
		(erase-buffer)
		(remove-overlays)

		(widget-insert (format "File: %s\n\n" org-incoming--cur-source))
		(widget-insert "Title: ")
		(setq org-incoming--w-name (widget-create 'editable-field
																					 :size 20
																					 :value " "))
		(widget-insert "\nDate: ")
		(setq org-incoming--w-date (widget-create 'org-incoming--datewidget
																							:size 10
																							:value guessed-date))
		(widget-insert "\n \n")
		(widget-setup)
		(goto-char 0)
		;(widget-minor-mode)
		(widget-forward 1)))

(defun org-incoming--find-free-filename (dir fname)
	"Find a free filename in DIR close to FNAME."
	(let ((counter 1)
				(current-try (format "%s/%s" dir fname))
				(extension (file-name-extension fname))
				(fname-base (file-name-sans-extension fname)))
		(while (file-exists-p current-try)
			(setq current-try (format "%s/%s_%03d.%s" dir
																fname-base counter extension))
			(setq counter (+ counter 1)))
		current-try))

(defun org-incoming--store ()
	"Complete the annotation phase and store annotation and PDF."
	(when (not (eq org-incoming--cur-phase 'annotated))
		(error "Current state not allowed for org-incoming--store"))

	(let ((pdfdir (file-name-directory org-incoming--cur-pdf-target))
				(annotdir (file-name-directory org-incoming--cur-annotation-target)))
		;; make sure there are no autosaves or locks present
		(save-buffer org-incoming--org-buf)
		(kill-buffer org-incoming--org-buf)
		(when (buffer-live-p org-incoming--pdf-buf)
			(kill-buffer org-incoming--pdf-buf))

		(make-directory pdfdir 't)
		(make-directory annotdir 't)

		(org-incoming--permissive-rename-file org-incoming--cur-source
																					org-incoming--cur-pdf-target)
		(org-incoming--permissive-rename-file org-incoming--cur-annotation-file
																					org-incoming--cur-annotation-target)

		(setq org-incoming--cur-phase 'stored)
		(org-incoming--next)))

(defun org-incoming--load (filename)
	"Load a new PDF file and initiate the query phase.

Loads the file pointed to by FILENAME."
	(when (not (or (eq org-incoming--cur-phase 'inactive)
								 (eq org-incoming--cur-phase 'skipped)
								 (eq org-incoming--cur-phase 'stored)))
		(error "Current state not allowed for org-incoming--load"))

	(message (format "Loading %s" filename))

	(setq org-incoming--cur-source filename)
	(when (and (bound-and-true-p org-incoming--pdf-buf)
						 (buffer-live-p org-incoming--pdf-buf))
		(set-buffer org-incoming--pdf-buf))

	(setq org-incoming--pdf-buf (find-file-noselect filename))
	;;		(display-buffer-same-window org-incoming--pdf-buf '())
	(display-buffer org-incoming--pdf-buf '(display-buffer-same-window . ()))
	(set-buffer org-incoming--pdf-buf)
	(org-incoming-pdf-mode)
	(org-incoming--init-form filename)
	(org-incoming--windows-for-query)

	(goto-char 0)
	(widget-forward 1)

	(setq org-incoming--cur-phase 'loaded))

(defun org-incoming--extract-text (fname)
	"Extract text from the PDF file.

This extracts text from the PDF file at FNAME and sets the variable
org-incoming--cur-extracted accordingly."
	(setq org-incoming--cur-extracted "")
	(condition-case nil
			(with-temp-buffer
					(call-process "pdftotext" nil (current-buffer) nil fname "-")

					;; Delete the bogus end output of pdftotext
					(goto-char (point-max))
					(let ((ctrl-l-pos (search-backward "" nil 't)))
						(when (not (eq ctrl-l-pos nil))
							(kill-region ctrl-l-pos (point-max))))
					(setq org-incoming--cur-extracted (buffer-string)))
		(file-missing (message "pdftotext not found. Install pdftotext to enable \
text extraction."))))

(defun org-incoming--create-org-file (cur-name cur-date)
  "Create a new org file template for annotation.

Sets title and date from CUR-NAME and CUR-DATE."
  (let* ((context `(("date" . ,cur-date)
                    ("title" . ,cur-name)
                    ("link" . ,org-incoming--cur-pdf-target)
                    ("extracted" . ,org-incoming--cur-extracted)))
         (content (s-format (org-incoming--get-setting "annotation-template")
                            'aget context)))
    
    (with-temp-buffer
      (insert content)
      (write-file org-incoming--cur-annotation-file))))

(defun org-incoming--create-roam-file (cur-name cur-date)
	"Create a new org-roam file template for annotation.

Sets title and date from CUR-NAME and CUR-DATE."
	;; org-id-get-create needs a buffer visiting a file.
	(setq org-incoming--temp-buf (find-file-noselect
																org-incoming--cur-annotation-file))
	(set-buffer org-incoming--temp-buf)

	;; Some versions of org-id-get-create can only add an ID after a
	;; heading. So we attach a dummy heading at the end of the file,
	;; create an ID, transplant that ID and its property drawer to the
	;; beginning of the file, and remove the dummy heading from the end again.
	(let ((length-before-dummy (point-max))
				(drawer-begin)
				(id-drawer-text))
		(goto-char (point-max))
		(insert "* Dummy Heading\n")
		(org-id-get-create)

		(goto-char length-before-dummy)
		(setq drawer-begin (- (search-forward ":") 2))
		
		(setq id-drawer-text
					(substring (buffer-string) drawer-begin))
		(delete-region length-before-dummy (point-max))
		(goto-char 0)
		;; Text from below the headline had some indentation, remove that
		(insert (replace-regexp-in-string " *:" ":" id-drawer-text))
		(goto-char (point-max)))
		
	(save-buffer)
	(kill-buffer org-incoming--temp-buf))


(defun org-incoming--annotate (cur-name cur-date)
	"Initialize the annotation phase.

Sets title and date from CUR-NAME and CUR-DATE."
	(when (not (eq org-incoming--cur-phase 'named))
		(error "Current state not allowed for org-incoming--annotate"))

	(org-incoming--extract-text org-incoming--cur-source)
	(org-incoming--create-org-file cur-name cur-date)
	
	(if (not (eq (org-incoming--get-setting "use-roam") nil))
			(org-incoming--create-roam-file cur-name cur-date))

	(setq org-incoming--org-buf (find-file-noselect
															 org-incoming--cur-annotation-file))
	(display-buffer org-incoming--org-buf '(display-buffer-same-window . ()))
	(org-incoming--windows-for-org)
	(org-incoming-org-mode)
	;; we want the temproray directory to be empty afterwards for safe deletion
	(setq backup-inhibited 't)

	(goto-char (point-max))
	(save-buffer)
	(setq org-incoming--cur-phase 'annotated))

(defun org-incoming--set-filenames (cur-name cur-date)
	"Set the destination filename variables based on CUR-NAME and CUR-DATE."
	(let* ((filename (org-incoming--sanitize-filename
										(replace-regexp-in-string " " "_" (string-trim cur-name))))
				 (target-filename-base (format "%s_%s.org" cur-date filename))
				 (target-filename (org-incoming--find-free-filename
													 org-incoming--cur-targetdir target-filename-base))
				 (target-pdfname-base (format "%s_%s.pdf" cur-date filename))
				 (target-pdfname (org-incoming--find-free-filename
													org-incoming--cur-targetdir-pdf target-pdfname-base)))

			(when (file-exists-p target-pdfname)
				(error (format "File '%s' exists" target-pdfname)))
			(when (file-exists-p target-filename)
				(error (format "File '%s' exists" target-filename)))

			(org-incoming--new-tempdir)

			(setq org-incoming--cur-annotation-target target-filename)
			(setq org-incoming--cur-pdf-target target-pdfname)
			(setq org-incoming--cur-annotation-file
						(expand-file-name "annotation.org" org-incoming--cur-tempdir))))

(defun org-incoming--handle-form ()
	"Handle a completed form from the query phase."
	(catch 'myexit
		(when (not (eq org-incoming--cur-phase 'loaded))
			(error "Current state not allowed for org-incoming--handle-form"))

		(when (org-incoming--validate-form)
			(throw 'myexit "exiting"))

		(let* ((cur-name (string-trim (widget-value org-incoming--w-name)))
					 (cur-date (string-trim (widget-value org-incoming--w-date)))
					 (inhibit-read-only t))

			(org-incoming--set-filenames cur-name cur-date)

			(widget-delete org-incoming--w-name)
			(widget-delete org-incoming--w-date)
			(setq org-incoming--w-name nil)
			(setq org-incoming--w-date nil)

			(setq org-incoming--cur-phase 'named)
			(org-incoming--annotate cur-name cur-date))))

(defun org-incoming--get-files-in-srcdir (sourcedir)
	"Return the PDF files in SOURCEDIR."
	(directory-files sourcedir 't ".*\\.pdf"))

(defun org-incoming--next-in-dir (dir-plist)
	"Start processing the next PDF file in the folder pair indicated \
by the plist DIR-PLIST."
	(when (not (or (eq org-incoming--cur-phase 'inactive)
								 (eq org-incoming--cur-phase 'skipped)
								 (eq org-incoming--cur-phase 'stored)))
		(error "Current state not allowed for org-incoming--next-in-dir"))

	(let ((sourcedir (plist-get dir-plist :source))
				(targetdir (plist-get dir-plist :target)))

		(when (not (stringp sourcedir))
			(error "Sourcedir must be string"))
		(when (not (stringp targetdir))
			(error "Targetdir must be string"))

		(setq org-incoming--cur-plist dir-plist)

		(let* ((dir-content (org-incoming--get-files-in-srcdir sourcedir))
					 (filtered-content (-remove (lambda (el)
																				(-contains? org-incoming--skipped el))
																			dir-content)))

			;; TODO make sure dirs exist
			(setq org-incoming--cur-targetdir targetdir)
			(setq org-incoming--cur-targetdir-pdf
						(format "%s/%s" targetdir (org-incoming--get-setting "pdf-subdir")))
			(if (eq filtered-content '())
					;; Return nil to signal 'no more files'
					nil
				;; Else, there are more files.  Load the first one of them
				;; returns the filename to signal success
				(org-incoming--load (car filtered-content))
				;; Whatever org-incoming--load returns, return 't to signal success
				't))))

(defun org-incoming--next ()
	"Start processing the next available PDF file."
	(when (not (or (eq org-incoming--cur-phase 'inactive)
								 (eq org-incoming--cur-phase 'skipped)
								 (eq org-incoming--cur-phase 'stored)))
		(error "Current state not allowed for org-incoming--next"))

	(-each-while org-incoming-dirs
			(lambda (dir)
				;; 'yes' means 'continue', so we must return non-nil if we did
				;; *not* successfully load a file
				(eq (org-incoming--next-in-dir dir) nil))
		;; The fn of -each-while is empty, we got our work done in the predicate
		(lambda (dir))))

(defun org-incoming--windows-for-query ()
	"Set up the windows and buffers of the active frame for the query phase."
	(setq org-incoming--query-win (display-buffer org-incoming--query-buf))
	(select-window org-incoming--query-win)
	(delete-other-windows)
	(setq org-incoming--pdf-win
				(display-buffer org-incoming--pdf-buf '(display-buffer-pop-up-window))))

(defun org-incoming--windows-for-org ()
	"Set up the windows and buffers of the active frame for the annotation phase."
	(setq org-incoming--org-win (display-buffer org-incoming--org-buf))
	(select-window org-incoming--org-win)
	(delete-other-windows)
	(setq org-incoming--pdf-win
				(display-buffer org-incoming--pdf-buf '(display-buffer-pop-up-window))))

(defun org-incoming-start ()
	"Start a new org-incoming session."
	(interactive)
	(message "Starting org-incoming session")
	(setq org-incoming--skipped '())
	(setq org-incoming--cur-tempdir nil) ;; Prevent deleting any random directory
	(setq org-incoming--cur-phase 'inactive)
	(org-incoming--next))

(provide 'org-incoming)
;;; org-incoming.el ends here