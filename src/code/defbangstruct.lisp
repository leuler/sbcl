;;;; DEF!STRUCT = bootstrap DEFSTRUCT, a wrapper around DEFSTRUCT which
;;;; provides special features to help at bootstrap time:
;;;;  1. Layout information, inheritance information, and so forth is
;;;;     retained in such a way that we can get to it even on vanilla
;;;;     ANSI Common Lisp at cross-compiler build time.
;;;;  2. MAKE-LOAD-FORM information is stored in such a way that we can
;;;;     get to it at bootstrap time before CLOS is built. This is
;;;;     important because at least as of sbcl-0.6.11.26, CLOS is built
;;;;     (compiled) after cold init, so we need to have the compiler
;;;;     even before CLOS runs.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!KERNEL")

;;; A bootstrap MAKE-LOAD-FORM method can be a function or the name
;;; of a function.
(deftype def!struct-type-make-load-form-fun () '(or function symbol))

;;; a little single-inheritance system to keep track of MAKE-LOAD-FORM
;;; information for DEF!STRUCT-defined types
(eval-when (#-sb-xc :compile-toplevel :load-toplevel :execute)

  ;; (DEF!STRUCT-SUPERTYPE TYPE) is the DEF!STRUCT-defined type that
  ;; TYPE inherits from, or NIL if none.
  (defvar *def!struct-supertype* (make-hash-table))
  (defun def!struct-supertype (type)
    (multiple-value-bind (value value-p) (gethash type *def!struct-supertype*)
      (unless value-p
        (error "~S is not a DEF!STRUCT-defined type." type))
      value))
  (defun (setf def!struct-supertype) (value type)
    (when (and value #-sb-xc-host *type-system-initialized*)
      (aver (subtypep value 'structure!object))
      (aver (subtypep type value)))
    (setf (gethash type *def!struct-supertype*) value))

  ;; (DEF!STRUCT-TYPE-MAKE-LOAD-FORM-FUN TYPE) is the load form
  ;; generator associated with the DEF!STRUCT-defined structure named
  ;; TYPE, stored in a way which works independently of CLOS. The
  ;; *DEF!STRUCT-TYPE-MAKE-LOAD-FORM-FUN* table is used to store the
  ;; values. All types defined by DEF!STRUCT have an entry in the
  ;; table; those with no MAKE-LOAD-FORM function have an explicit NIL
  ;; entry.
  (defvar *def!struct-type-make-load-form-fun* (make-hash-table))
  (defun def!struct-type-make-load-form-fun (type)
    (do ((supertype type))
        (nil)
      (multiple-value-bind (value value-p)
          (gethash supertype *def!struct-type-make-load-form-fun*)
        (unless value-p
          (error "~S (supertype of ~S) is not a DEF!STRUCT-defined type."
                 supertype
                 type))
        (when value
          (return value))
        (setf supertype (def!struct-supertype supertype))
        (unless supertype
          (error "There is no MAKE-LOAD-FORM function for bootstrap type ~S."
                 type)))))
  (defun (setf def!struct-type-make-load-form-fun) (new-value type)
    (when #+sb-xc-host t #-sb-xc-host *type-system-initialized*
      (aver (subtypep type 'structure!object))
      (aver (typep new-value 'def!struct-type-make-load-form-fun)))
    (setf (gethash type *def!struct-type-make-load-form-fun*) new-value)))

;;; the simplest, most vanilla MAKE-LOAD-FORM function for DEF!STRUCT
;;; objects
;;; If, in general, we could reverse-engineer that when a user-written
;;; MAKE-LOAD-FORM was (MAKE-LOAD-FORM-SAVING-SLOTS ...) in an expected way,
;;; we could obtain fasl-op-based dumping of user-defined structures.
;;; At present we've no way to infer when the semantics of the Lisp code
;;; produced by MAKE-LOAD-FORM-SAVING-SLOTS is effectively the same as
;;; "dump the layout, dump the slots" (a/k/a :just-dump-it-normally).
;;; Barring that, there's no choice but to compile code to recreate users'
;;; constant structures. Otherwise we could nearly eliminate DEF!STRUCT too.
;;; Consider its objectives:
;;;  - enable efficient structure dumping
;;;  - inform the cross-compiler of SBCL-style metadata using only ANSI Lisp
;;;  - doing it *before* the defining form has been seen during cross-compile
;;;  - (maybe) even during building of the XC
;;; Of those goals, all but the last can be achieved by writing an ordinary
;;; DEFSTRUCT, putting it early enough, and attaching a magic property to
;;; the symbol naming your DEFSTRUCT. Witness that "backq.lisp" contains a
;;; manipulatable dumpable defstruct, modulo a problem that would be fixed by
;;; just delaying until after defsetfs is processed. backq is unique in that
;;; no other defstruct has the distinction of preceding defsetfs.
(defun just-dump-it-normally (object &optional (env nil env-p))
  (declare (type structure!object object))
  (declare (ignorable env env-p object))
  ;; KLUDGE: we require essentially three different behaviours of
  ;; JUST-DUMP-IT-NORMALLY, two of which (host compiler's
  ;; MAKE-LOAD-FORM, cross-compiler's MAKE-LOAD-FORM) are handled by
  ;; the #+SB-XC-HOST clause.  The #-SB-XC-HOST clause is the
  ;; behaviour required by the target, before the CLOS-based
  ;; MAKE-LOAD-FORM-SAVING-SLOTS is implemented.
  #+sb-xc-host
  (if env-p
      (sb!xc:make-load-form-saving-slots object :environment env)
      (sb!xc:make-load-form-saving-slots object))
  #-sb-xc-host
  :sb-just-dump-it-normally)

;;; a MAKE-LOAD-FORM function for objects which don't use the load
;;; form system. This is used for LAYOUT objects because the special
;;; dumping requirements of LAYOUT objects are met by using special
;;; VOPs which bypass the load form system. It's also used for various
;;; compiler internal structures like nodes and VOP-INFO (FIXME:
;;; Why?).
(defun ignore-it (object &optional env)
  (declare (type structure!object object))
  (declare (ignore object env))
  ;; This magic tag is handled specially by the compiler downstream.
  :ignore-it)

;;; machinery used in the implementation of DEF!STRUCT
#+sb-xc-host
(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; a description of a DEF!STRUCT call to be stored until we get
  ;; enough of the system running to finish processing it
  (defstruct delayed-def!struct
    (args (missing-arg) :type cons)
    (package (sane-package) :type package))
  ;; a list of DELAYED-DEF!STRUCTs stored until we get DEF!STRUCT
  ;; working fully so that we can apply it to them then. After
  ;; DEF!STRUCT is made to work fully, this list is processed, then
  ;; made unbound, and should no longer be used.
  (defvar *delayed-def!structs* nil))
(eval-when (#-sb-xc :compile-toplevel :load-toplevel :execute)
  ;; Parse the arguments for a DEF!STRUCT call, and return
  ;;   (VALUES NAME DEFSTRUCT-ARGS MAKE-LOAD-FORM-FUN DEF!STRUCT-SUPERTYPE),
  ;; where NAME is the name of the new type, DEFSTRUCT-ARGS is the
  ;; munged result suitable for passing on to DEFSTRUCT,
  ;; MAKE-LOAD-FORM-FUN is the make load form function, or NIL if
  ;; there's none, and DEF!STRUCT-SUPERTYPE is the direct supertype of
  ;; the type if it is another DEF!STRUCT-defined type, or NIL
  ;; otherwise.
  (defun parse-def!struct-args (nameoid &rest rest)
    (multiple-value-bind (name options) ; Note: OPTIONS can change below.
        (if (consp nameoid)
            (values (first nameoid) (rest nameoid))
            (values nameoid nil))
      (declare (type list options))
      (let* ((include-clause (find :include options :key #'first))
             (def!struct-supertype nil) ; may change below
             (mlff-clause (find :make-load-form-fun options :key #'first))
             (mlff (and mlff-clause (second mlff-clause))))
        (when (find :type options :key #'first)
          (error "can't use :TYPE option in DEF!STRUCT"))
        (when mlff-clause
          (setf options (remove mlff-clause options)))
        (when include-clause
          (setf def!struct-supertype (second include-clause)))
        (if (eq name 'structure!object) ; if root of hierarchy
            (aver (not include-clause))
            (unless include-clause
              (setf def!struct-supertype 'structure!object)
              (push `(:include ,def!struct-supertype) options)))
        (values name `((,name ,@options) ,@rest) mlff def!struct-supertype)))))

;;; Part of the raison d'etre for DEF!STRUCT is to be able to emulate
;;; these low-level CMU CL functions in a vanilla ANSI Common Lisp
;;; cross compilation host. (The emulation doesn't need to be
;;; efficient, since it's needed for things like dumping objects, not
;;; inner loops.)
#+sb-xc-host
(progn
  (defun xc-dumpable-structure-instance-p (x)
    (and (typep x 'cl:structure-object)
         (let ((name (type-of x)))
           ;; Don't allow totally random structures, only ones that the
           ;; cross-compiler has been advised will work.
           (and (get name :sb-xc-allow-dumping-instances)
                ;; but we must also have cross-compiled it for real.
                (sb!kernel::compiler-layout-ready-p name)
                ;; and I don't know anything about raw slots
                ;; Coincidentally, in either representation of
                ;; raw-slot-metadata, 0 represents no untagged slots.
                (zerop (layout-raw-slot-metadata
                        (info :type :compiler-layout name)))))))
  (defun %instance-layout (instance)
    (aver (or (typep instance 'structure!object)
              (xc-dumpable-structure-instance-p instance)))
    (classoid-layout (find-classoid (type-of instance))))
  (defun %instance-length (instance)
    ;; INSTANCE-LENGTH tells you how many data words the backend is able to
    ;; physically access in this structure. Since every structure occupies
    ;; an even number of words, the storage slots comprise an odd number
    ;; of words after subtracting 1 for the header.
    ;; And in fact the fasl dumper / loader do write and read potentially
    ;; one cell beyond the instance's LAYOUT-LENGTH if it was not odd.
    ;; I'm not sure whether that is a good or bad thing.
    ;; But be that as it may, in the cross-compiler you must not access
    ;; more cells than there are in the declared structure because there
    ;; is no lower level storage that you can peek at.
    ;; So INSTANCE-LENGTH is exactly the same as LAYOUT-LENGTH on the host.
    (layout-length (%instance-layout instance)))
  (defun %instance-ref (instance index)
    (let ((layout (%instance-layout instance)))
      ;; with compact headers, 0 is an ordinary slot index.
      ;; without, it's the layout.
      (if (eql index (1- sb!vm:instance-data-start))
          (error "XC Host should use %INSTANCE-LAYOUT, not %INSTANCE-REF 0")
          (let* ((dd (layout-info layout))
                 ;; If data starts at 1, then subtract 1 from index.
                 ;; otherwise use the index as-is.
                 (dsd (elt (dd-slots dd)
                           (- index sb!vm:instance-data-start)))
                 (accessor-name (dsd-accessor-name dsd)))
            ;; Why AVER these: because it is slightly abstraction-breaking
            ;; to assume that the slot-index N is the NTH item in the DSDs.
            ;; The target Lisp never assumes that.
            (aver (and (eql (dsd-index dsd) index) (eq (dsd-raw-type dsd) t)))
            (funcall accessor-name instance)))))
  ;; I believe this approach is technically nonportable because CLHS says that
  ;;  "The mechanism by which defstruct arranges for slot accessors to be usable
  ;;   with setf is implementation-dependent; for example, it may use setf
  ;;   functions, setf expanders, or some other implementation-dependent
  ;;   mechanism ..."
  ;; As it happens, many implementations provide both functions and expanders.
  ;; But ... this seems never to be needed.
  (defun %instance-set (instance index new-value)
    (aver (typep instance 'structure!object)) ; a stronger condition than above
    (let ((layout (%instance-layout instance)))
      (if (< index sb!vm:instance-data-start)
          (error "can't set %INSTANCE-REF FOO 0 in cross-compilation host")
          (let* ((dd (layout-info layout))
                 (dsd (elt (dd-slots dd) (- index sb!vm:instance-data-start)))
                 (accessor-name (dsd-accessor-name dsd)))
            (declare (type symbol accessor-name))
            (funcall (fdefinition `(setf ,accessor-name))
                     new-value
                     instance))))))

;;; a helper function for DEF!STRUCT in the #+SB-XC-HOST case: Return
;;; DEFSTRUCT-style arguments with any class names in the SB!XC
;;; package (i.e. the name of the class being defined, and/or the
;;; names of classes in :INCLUDE clauses) converted from SB!XC::FOO to
;;; CL::FOO.
#+sb-xc-host
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun uncross-defstruct-args (defstruct-args)
    (destructuring-bind (name-and-options &rest slots-and-doc) defstruct-args
      (multiple-value-bind (name options)
          (if (symbolp name-and-options)
              (values name-and-options nil)
              (values (first name-and-options)
                      (rest name-and-options)))
        (flet ((uncross-option (option)
                 (if (eq (first option) :include)
                     (destructuring-bind
                         (include-keyword included-name &rest rest)
                         option
                       `(,include-keyword
                         ,(uncross included-name)
                         ,@rest))
                   option)))
          `((,(uncross name)
             ,@(mapcar #'uncross-option options))
            ,@slots-and-doc))))))

;;; DEF!STRUCT's arguments are like DEFSTRUCT's arguments, except that
;;; DEF!STRUCT accepts an extra optional :MAKE-LOAD-FORM-FUN clause.
;;; DEF!STRUCT also does some magic to ensure that anything it defines
;;; includes STRUCTURE!OBJECT, so that when CLOS is/becomes available,
;;; we can hook the DEF!STRUCT system into
;;;   (DEFMETHOD MAKE-LOAD-FORM ((X STRUCTURE!OBJECT) &OPTIONAL ENV) ..)
;;; and everything will continue to work.
(defmacro def!struct (&rest args)
  (multiple-value-bind (name defstruct-args mlff def!struct-supertype)
      (apply #'parse-def!struct-args args)
    `(progn
       ;; There are two valid cases here: creating the
       ;; STRUCTURE!OBJECT root of the inheritance hierarchy, or
       ;; inheriting from STRUCTURE!OBJECT somehow.
      ;;
       ;; The invalid case that we want to exclude is when an :INCLUDE
       ;; clause was used, and the included class didn't inherit frmo
       ;; STRUCTURE!OBJECT. We want to catch that error ASAP because
       ;; otherwise the bug might lurk until someone tried to do
       ;; MAKE-LOAD-FORM on an instance of the class.
       ,@(if (eq name 'structure!object)
             (aver (null def!struct-supertype))
             `((aver (subtypep ',def!struct-supertype 'structure!object))))
       (defstruct ,@defstruct-args)
       (setf (def!struct-type-make-load-form-fun ',name)
             ,(if (symbolp mlff)
                  `',mlff
                  mlff)
             (def!struct-supertype ',name)
             ',def!struct-supertype)
       #+sb-xc-host ,(let ((u (uncross-defstruct-args defstruct-args)))
                       (if (boundp '*delayed-def!structs*)
                           `(push (make-delayed-def!struct :args ',u)
                                  *delayed-def!structs*)
                           `(sb!xc:defstruct ,@u)))
       ',name)))

;;; When building the cross-compiler, this function has to be called
;;; some time after SB!XC:DEFSTRUCT is set up, in order to take care
;;; of any processing which had to be delayed until then.
#+sb-xc-host
(defun force-delayed-def!structs ()
  (if (boundp '*delayed-def!structs*)
      (progn
        (mapcar (lambda (x)
                  (let ((*package* (delayed-def!struct-package x)))
                    ;; KLUDGE(?): EVAL is almost always the wrong thing.
                    ;; However, since we have to map DEFSTRUCT over the
                    ;; list, and since ANSI declined to specify any
                    ;; functional primitives corresponding to the
                    ;; DEFSTRUCT macro, it seems to me that EVAL is
                    ;; required in there somewhere..
                    (eval `(sb!xc:defstruct ,@(delayed-def!struct-args x)))))
                (reverse *delayed-def!structs*))
        ;; We shouldn't need this list any more. Making it unbound
        ;; serves as a signal to DEF!STRUCT that it needn't delay
        ;; DEF!STRUCTs any more. It is also generally a good thing for
        ;; other reasons: it frees garbage, and it discourages anyone
        ;; else from pushing anything else onto the list later.
        (makunbound '*delayed-def!structs*))
      ;; This condition is probably harmless if it comes up when
      ;; interactively experimenting with the system by loading a source
      ;; file into it more than once. But it's worth warning about it
      ;; because it definitely shouldn't come up in an ordinary build
      ;; process.
      (warn "*DELAYED-DEF!STRUCTS* is already unbound.")))

;;; The STRUCTURE!OBJECT abstract class is the base of the type
;;; hierarchy for objects which have/use DEF!STRUCT functionality.
;;; (The extra hackery in DEF!STRUCT-defined things isn't needed for
;;; STRUCTURE-OBJECTs defined by ordinary, post-warm-init programs, so
;;; it's only put into STRUCTURE-OBJECTs which inherit from
;;; STRUCTURE!OBJECT.)
(def!struct (structure!object (:constructor nil) (:copier nil) (:predicate nil)))

;;;; hooking this all into the standard MAKE-LOAD-FORM system

;;; MAKE-LOAD-FORM for DEF!STRUCT-defined types
(defun structure!object-make-load-form (object &optional env)
  (declare (ignore env))
  (funcall (def!struct-type-make-load-form-fun (type-of object))
           object))

;;; Do the right thing at cold load time.
;;;
;;; (Eventually this MAKE-LOAD-FORM function be overwritten by CLOS's
;;; generic MAKE-LOAD-FORM, at which time a STRUCTURE!OBJECT method
;;; should be added to call STRUCTURE!OBJECT-MAKE-LOAD-FORM.)
(setf (symbol-function 'sb!xc:make-load-form)
      #'structure!object-make-load-form)

;;; Do the right thing in the vanilla ANSI CLOS of the
;;; cross-compilation host. (Something similar will have to be done in
;;; our CLOS, too, but later, some time long after the toplevel forms
;;; of this file have run.)
#+sb-xc-host
(defmethod make-load-form ((obj structure!object) &optional (env nil env-p))
  (if env-p
      (structure!object-make-load-form obj env)
      (structure!object-make-load-form obj)))
