;;; scan-api --- Scan and group interpreter and libguile interface elements

;; 	Copyright (C) 2002, 2006, 2011 Free Software Foundation, Inc.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU Lesser General Public License
;; as published by the Free Software Foundation; either version 3, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; Lesser General Public License for more details.
;;
;; You should have received a copy of the GNU Lesser General Public
;; License along with this software; see the file COPYING.LESSER.  If
;; not, write to the Free Software Foundation, Inc., 51 Franklin
;; Street, Fifth Floor, Boston, MA 02110-1301 USA

;;; Author: Thien-Thi Nguyen <ttn@gnu.org>

;;; Commentary:

;; Usage: scan-api GUILE SOFILE [GROUPINGS ...]
;;
;; Invoke GUILE, an executable guile interpreter, and use nm(1) on SOFILE, a
;; shared-object library, to determine available interface elements, and
;; display them to stdout as an alist:
;;
;;   ((meta ...) (interface ...))
;;
;; The meta fields are `GUILE_LOAD_PATH', `LTDL_LIBRARY_PATH', `guile'
;; `libguileinterface', `sofile' and `groups'.  The interface elements are in
;; turn sub-alists w/ keys `groups' and `scan-data'.  Interface elements
;; initially belong in one of two groups `Scheme' or `C' (but not both --
;; signal error if that happens).
;;
;; Optional GROUPINGS ... are files each containing a single "grouping
;; definition" alist with each entry of the form:
;;
;;   (NAME (description "DESCRIPTION") (members SYM...))
;;
;; All of the SYM... should be proper subsets of the interface.  In addition
;; to `description' and `members' forms, the entry may optionally include:
;;
;;   (grok USE-MODULES (lambda (x) CODE))
;;
;; where CODE implements a group-membership predicate to be applied to `x', a
;; symbol.  [When evaluated, CODE can assume (use-modules MODULE) has been
;; executed where MODULE is an element of USE-MODULES, a list.  [NOT YET
;; IMPLEMENTED!]]
;;
;; Currently, there are two convenience predicates that operate on `x':
;;   (in-group? x GROUP)
;;   (name-prefix? x PREFIX)
;;
;; TODO: Allow for concurrent Scheme/C membership.
;;       Completely separate reporting.

;;; Code:

(define-module (scripts scan-api)
  :use-module (ice-9 popen)
  :use-module (ice-9 rdelim)
  :use-module (ice-9 regex)
  :export (scan-api))

(define %include-in-guild-list #f)
(define %summary "Generate an API description for a Guile extension.")

(define put set-object-property!)
(define get object-property)

(define (add-props object . args)
  (let loop ((args args))
    (if (null? args)
        object                          ; retval
        (let ((key (car args))
              (value (cadr args)))
          (put object key value)
          (loop (cddr args))))))

(define (scan re command match)
  (let ((rx (make-regexp re))
        (port (open-pipe command OPEN_READ)))
    (let loop ((line (read-line port)))
      (or (eof-object? line)
          (begin
            (cond ((regexp-exec rx line) => match))
            (loop (read-line port)))))))

(define (scan-Scheme! ht guile)
  (scan "^.guile.+: ([^ \t]+)([ \t]+(.+))*$"
        (format #f "~A -c '~S ~S'"
                guile
                '(use-modules (ice-9 session))
                '(apropos "."))
        (lambda (m)
          (let ((x (string->symbol (match:substring m 1))))
            (put x 'Scheme (or (match:substring m 3)
                               ""))
            (hashq-set! ht x #t)))))

(define (scan-C! ht sofile)
  (scan "^[0-9a-fA-F]+ ([B-TV-Z]) (.+)$"
        (format #f "nm ~A" sofile)
        (lambda (m)
          (let ((x (string->symbol (match:substring m 2))))
            (put x 'C (string->symbol (match:substring m 1)))
            (and (hashq-get-handle ht x)
                 (error "both Scheme and C:" x))
            (hashq-set! ht x #t)))))

(define THIS-MODULE (current-module))

(define (in-group? x group)
  (memq group (get x 'groups)))

(define (name-prefix? x prefix)
  (string-match (string-append "^" prefix) (symbol->string x)))

(define (add-group-name! x name)
  (put x 'groups (cons name (get x 'groups))))

(define (make-grok-proc name form)
  (let* ((predicate? (eval form THIS-MODULE))
         (p (lambda (x)
              (and (predicate? x)
                   (add-group-name! x name)))))
    (put p 'name name)
    p))

(define (make-members-proc name members)
  (let ((p (lambda (x)
             (and (memq x members)
                  (add-group-name! x name)))))
    (put p 'name name)
    p))

(define (make-grouper files)            ; \/^^^o/ . o
  (let ((hook (make-hook 1)))           ; /\____\
    (for-each
     (lambda (file)
       (for-each
        (lambda (gdef)
          (let ((name (car gdef))
                (members (assq-ref gdef 'members))
                (grok (assq-ref gdef 'grok)))
            (or members grok
                (error "bad grouping, must have `members' or `grok'"))
            (add-hook! hook
                       (if grok
                           (add-props (make-grok-proc name (cadr grok))
                                      'description
                                      (assq-ref gdef 'description))
                           (make-members-proc name members))
                       #t)))            ; append
        (read (open-file file OPEN_READ))))
     files)
    hook))

(define (scan-api . args)
  (let ((guile (list-ref args 0))
        (sofile (list-ref args 1))
        (grouper (false-if-exception (make-grouper (cddr args))))
        (ht (make-hash-table 3331)))
    (scan-Scheme! ht guile)
    (scan-C!      ht sofile)
    (let ((all (sort (hash-fold (lambda (key value prior-result)
                                  (add-props
                                   key
                                   'string (symbol->string key)
                                   'scan-data (or (get key 'Scheme)
                                                  (get key 'C))
                                   'groups (if (get key 'Scheme)
                                               '(Scheme)
                                               '(C)))
                                  (and grouper (run-hook grouper key))
                                  (cons key prior-result))
                                '()
                                ht)
                     (lambda (a b)
                       (string<? (get a 'string)
                                 (get b 'string))))))
      (format #t ";;; generated by scan-api -- do not edit!\n\n")
      (format #t "(\n")
      (format #t "(meta\n")
      (format #t "  (GUILE_LOAD_PATH . ~S)\n"
              (or (getenv "GUILE_LOAD_PATH") ""))
      (format #t "  (LTDL_LIBRARY_PATH . ~S)\n"
              (or (getenv "LTDL_LIBRARY_PATH") ""))
      (format #t "  (guile . ~S)\n" guile)
      (format #t "  (libguileinterface . ~S)\n"
              (let ((i #f))
                (scan "(.+)"
                      (format #f "~A -c '(display ~A)'"
                              guile
                              '(assq-ref %guile-build-info
                                         'libguileinterface))
                      (lambda (m) (set! i (match:substring m 1))))
                i))
      (format #t "  (sofile . ~S)\n" sofile)
      (format #t "  ~A\n"
              (cons 'groups (append (if grouper
                                        (map (lambda (p) (get p 'name))
                                             (hook->list grouper))
                                        '())
                                    '(Scheme C))))
      (format #t ") ;; end of meta\n")
      (format #t "(interface\n")
      (for-each (lambda (x)
                  (format #t "(~A ~A (scan-data ~S))\n"
                          x
                          (cons 'groups (get x 'groups))
                          (get x 'scan-data)))
                all)
      (format #t ") ;; end of interface\n")
      (format #t ") ;; eof\n")))
  #t)

(define main scan-api)

;;; scan-api ends here
