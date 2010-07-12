;;; -*- Mode: lisp; Syntax: ansi-common-lisp; Base: 10; Package: org.apache.thrift.implementation; -*-

(in-package :org.apache.thrift.implementation)

;;; This file implements service instance and a server interface for the `org.apache.thrift` library.
;;;
;;; copyright 2010 [james anderson](james.anderson@setf.de)
;;;
;;; Licensed to the Apache Software Foundation (ASF) under one
;;; or more contributor license agreements. See the NOTICE file
;;; distributed with this work for additional information
;;; regarding copyright ownership. The ASF licenses this file
;;; to you under the Apache License, Version 2.0 (the
;;; "License"); you may not use this file except in compliance
;;; with the License. You may obtain a copy of the License at
;;; 
;;;   http://www.apache.org/licenses/LICENSE-2.0
;;; 
;;; Unless required by applicable law or agreed to in writing,
;;; software distributed under the License is distributed on an
;;; "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
;;; KIND, either express or implied. See the License for the
;;; specific language governing permissions and limitations
;;; under the License.


;;; The principal Thrift entity for reomte interaction is the `service`. A service is a named
;;; collection of operations. A server associates a service with a listening port, accepts
;;; request for named operations, decodes and dsipatchs data to the service's operations,
;;; encodes the results and returns them them to thr requesting client.


(defclass service ()
  ((name
    :initform nil :initarg :name
    :reader service-name)
   (base-services
    :initform nil :initarg :base-services
    :accessor service-base-services)
   (methods
    :reader service-methods)
   (documentation
     :initform nil :initarg :documentation
     :accessor service-documentation))
  (:documentation "A named service associates methods with their names. When created with def-service
 each service is bound to a global parameter named as its Lisp equivalent. A service can also
 serve as the root for a set of subsidiary services, to which it defers method look-ups."))


(defclass server ()
  ((services
    :initform nil :initarg :services
    :accessor server-services
    :documentation "A sequence of services, each of which binds its set of operators
     to external names. When accepting a message, the server locates some service which
     can respond toit, and delegates the processing to that service. If none is found
     an exception is returned."))
  (:documentation "A server associates a root service with a request transport."))


(defclass socket-server (server)
  ((socket :accessor server-socket :initarg :socket))
  (:documentation "The server class which combines services with a listening socket."))


(defclass thrift (puri:uri)
  ()
  (:documentation "A specialized URI class to distinguish Thrift locations when constructing a
 server."))


;;;
;;; service operators

(defmethod initialize-instance :after ((instance service) &key methods)
  (etypecase methods
    (hash-table (setf (slot-value instance 'methods) methods))
    (list (setf (slot-value instance 'methods)
                (apply #'thrift:map methods)))))

(defmethod print-object ((object service) stream)
  (print-unreadable-object (object stream :identity t :type t)
    (format stream "~@[~a~]" (service-name object))))

(defgeneric find-thrift-function (service identifier)
  (:method ((service service) (identifier string))
    (flet ((delegate-find (service) (find-thrift-function service identifier)))
      (declare (dynamic-extent #'delegate-find))
      (or (gethash identifier (service-methods service))
          (some #'delegate-find (service-base-services service))))))

(defgeneric (setf find-thrift-function) (function service identifier)
  (:method ((function thrift-generic-function) (service service) (identifier string))
    (setf (gethash identifier (service-methods service)) function))
  (:method ((function null) (service service) (identifier string))
    (remhash identifier (service-methods service))))


;;;
;;; server operators

(defgeneric server-input-transport (server connection)
  (:method ((server socket-server) (socket usocket:usocket))
    (make-instance 'socket-transport :socket socket :direction :input)))

(defgeneric server-output-transport (server connection)
  (:method ((server socket-server) (socket usocket:usocket))
    (make-instance 'socket-transport :socket socket :direction :output)))
    

(defmethod accept-connection ((s socket-server))
  (usocket:socket-accept (server-socket s) :element-type 'unsigned-byte))

(defmethod server-close ((s socket-server))
  (usocket:socket-close (server-socket s)))

(defgeneric server-protocol (server input output)
  (:method ((server socket-server) input output)
    (make-instance 'binary-protocol :input-transport input :output-transport output
                   :direction :io)))


(defparameter *debug-server* t)

(defgeneric serve (connection-server service)
  (:documentation "Accept to a CONNECTION-SERVER, configure the CLIENT's transport and protocol
 in combination with the connection, and process messages until the connection closes.")

  (:method ((location thrift) service)
    "Given a basic thrift uri, open a binary socket server and listen on the port."
    (let ((server (make-instance 'socket-server
                    :socket (usocket:socket-listen (puri:uri-host location) (puri:uri-port location)
                                                   :element-type 'unsigned-byte
                                                   :reuseaddress t))))
      (unwind-protect (serve server service)
        (server-close server))))

  (:method ((s socket-server) (service service))
    (loop 
      (let ((connection (accept-connection s)))
        (if (open-stream-p (usocket:socket-stream connection))
          (let* ((input-transport (server-input-transport s connection))
                 (output-transport (server-output-transport s connection))
                 (protocol (server-protocol s input-transport output-transport)))
            (unwind-protect (block :process-loop
                              (handler-bind ((end-of-file (lambda (eof)
                                                            (declare (ignore eof))
                                                            (return-from :process-loop)))
                                             (error (lambda (error)
                                                      (if *debug-server*
                                                        (break "Server error: ~s: ~a" s error)
                                                        (warn "Server error: ~s: ~a" s error))
                                                      (stream-write-exception protocol error)
                                                      (return-from :process-loop))))
                                (loop (unless (open-stream-p input-transport) (return))
                                      (process service protocol))))
              (print (list :closing connection (usocket:socket-stream connection)))
              (close input-transport)
              (close output-transport)))
          ;; listening socket closed
          (return))))))

  
(defgeneric process (service protocol)
  (:documentation "Combine a service PEER with an input-protocol and an output-protocol to control processing
 the next message on the peer's input connection. The base method reads the message, decodes the
 function and the arguments, invokes the method, and replies with the results.
 The protocols are initially those of the peer itself, but they are passed her in order to permit
 wrapping for logging, etc.")

  (:method ((service service) (protocol t))
    (flet ((consume-message ()
             (prog1 (stream-read-struct protocol)
               (stream-read-message-end protocol))))
      (multiple-value-bind (identifier type sequence-number) (stream-read-message-begin protocol)
        (ecase type
          ((call oneway)
           (let ((operator (find-thrift-function service identifier)))
             (cond (operator
                    (funcall operator service sequence-number protocol)
                    (stream-read-message-end protocol))
                   (t
                    (unknown-method protocol identifier sequence-number (consume-message))))))
          (reply
           (unexpected-response protocol identifier sequence-number (consume-message)))
          (exception
           (request-exception protocol identifier sequence-number (consume-message))))))))

