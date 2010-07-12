;;; -*- Mode: lisp; Syntax: ansi-common-lisp; Base: 10; Package: thrift-test; -*-

(in-package :thrift-test)

;;; tests for definition operators
;;; (run-tests "def-.*")

(test def-package.1
      (progn (def-package :test-package)
             (prog1 (and (find-package :test-package)
                         (find-package :test-package-request)
                         (find-package :test-package-response))
               (delete-package :test-package)
               (delete-package :test-package-request)
               (delete-package :test-package-response))))

(test def-package.2
      (progn (def-package :test-package)
             (def-package :test-package)
             (prog1 (and (find-package :test-package)
                         (find-package :test-package-request)
                         (find-package :test-package-response))
               (delete-package :test-package)
               (delete-package :test-package-request)
               (delete-package :test-package-response))))

(test def-enum
      (progn (def-enum "TestEnum" ((first . 1) (second . 2)))
             (prog1 (and (eql (symbol-value 'test-enum.first) 1)
                         (eql (symbol-value 'test-enum.second) 2))
               (unintern 'test-enum)
               (unintern 'test-enum.first)
               (unintern 'test-enum.second))))

(test def-constant
      (progn (def-constant "aConstant" 1)
             (prog1 (eql (symbol-value 'a-constant) 1)
               (unintern 'a-constant))))

(test def-struct
      (locally
        (declare (ftype (function (t) t) test-struct-field3 test-struct-field2 test-struct-field1))
        (def-struct "testStruct" ())
        (def-struct "testStruct"
          (("field1" 0 :type i32 :id 1)
           ("field2" nil :type i16 :id 2)
           ("field3" "string value" :type string :id 3)))
        (let ((struct (make-instance 'test-struct :field1 -1)))
          (prog1 (and (equal (test-struct-field3 struct) "string value")
                      (not (slot-boundp struct 'field2))
                      (equal (test-struct-field1 struct) -1)
                      (typep (nth-value 1 (ignore-errors (setf (test-struct-field2 struct) 1.1)))
                             ;; some implementation may not constrain
                             ;; some signal a type error
                             #+ccl 'type-error
                             #+sbcl 'null))        ; how to enable slot type checks?
            (mapc #'(lambda (method) (remove-method (c2mop:method-generic-function method) method))
                  (c2mop:specializer-direct-methods (find-class 'test-struct)))
            (setf (find-class 'test-struct) nil)))))

(test def-exception
      (locally
        (declare (ftype (function (t) t) test-exception-reason))
        (def-exception "testException" (("reason" nil :type string :id 1)))
        (let ((ex (make-condition 'test-exception :reason "testing")))
          (prog1 (and (equal (test-exception-reason ex) "testing")
                      (eq (cl:type-of (nth-value 1 (ignore-errors (error ex))))
                          'test-exception)
                      (stringp (princ-to-string ex)))
            (mapc #'(lambda (method) (remove-method (c2mop:method-generic-function method) method))
                  (c2mop:specializer-direct-methods (find-class 'test-exception)))
            (mapc #'(lambda (method) (remove-method (c2mop:method-generic-function method) method))
                  (c2mop:specializer-direct-methods (find-class 'test-exception-thrift-class)))
            (setf (find-class 'test-exception) nil)
            (setf (find-class 'test-exception-thrift-class) nil)))))



(test def-service
      (progn (defun test-method (arg1 arg2) (format nil "~a ~a" arg1 arg2))
             (def-service "TestService" nil
               (:method "testMethod" ((("arg1" i32 1) ("arg2" string 2)) string)))
             (let (request-protocol
                   response-protocol
                   (run-response-result nil))
               (flet ((run-response (request-protocol)
                        (rewind request-protocol)
                        (multiple-value-bind (name type seq)
                                             (thrift::stream-read-message-begin response-protocol)
                          (declare (ignore seq))
                          (setf run-response-result
                                (when (and (equal name "testMethod")
                                           (eq type 'call))
                                  (funcall 'thrift-test-response::test-method t t response-protocol))))))
                 (multiple-value-setq (request-protocol response-protocol)
                   (make-test-protocol-peers :request-hook #'run-response))
                 
                 (prog1 (and (equal (funcall 'thrift-test-request::test-method request-protocol 1 "testing")
                                    "1 testing")
                             ;; if the first test succeed, this should also be true
                             (equal run-response-result "1 testing"))
                   (fmakunbound 'test-method)
                   (fmakunbound 'thrift-test-request::test-method)
                   (fmakunbound 'thrift-test-response::test-method))))))




