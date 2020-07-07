#lang racket/base

(provide (all-defined-out))

(struct task-msg (task msg) #:transparent)
(struct task-msg:restart task-msg () #:transparent)
(struct task-msg:restart:worker-thread  task-msg:restart () #:transparent)
(struct task-msg:restart:timeout  task-msg:restart () #:transparent)

(define (make-task-msg:restart:worker-thread the-task)
  (task-msg:restart:worker-thread the-task "Task restarting. Reason: worker thread finished (normally or had an exception) without sending a completion message to manager"))

(define (make-task-msg:restart:timeout the-task)
  (task-msg:restart:timeout the-task "Task restarting. Reason: worker thread did not send message to manager within timeout period"))


