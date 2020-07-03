#lang racket

(require racket/async-channel
         racket/splicing
         struct-plus-plus
         "private/task.rkt")

;;----------------------------------------------------------------------

(provide start-majordomo
         stop-majordomo

         start-task

         majordomo?
         majordomo-id       majordomo.id

         ; Provide only the public-facing task-related functions.  That means not the
         ; channel for talking to the manager thread, or the custodian, or either of the
         ; constructors, or any of the setters except for status and data.
         task?
         task-proc        task.proc
         task-id          task.id
         task-status      task.status
         task-data        task.data
         task-manager-ch  task.manager-ch
         set-task-status
         set-task-data)

;;----------------------------------------------------------------------

(struct++ majordomo
          ([(id    (gensym "majordomo-"))  symbol?]  ; makes it human-identifiable
           [(cust  (make-custodian))       custodian?]))

;;----------------------------------------------------------------------

(define (start-majordomo)
  (majordomo++))

;;----------------------------------------------------------------------

(define/contract (stop-majordomo jarvis)
  (-> majordomo? any)
  (custodian-shutdown-all (majordomo.cust jarvis)))

;;----------------------------------------------------------------------

(define/contract (start-task jarvis proc [initial-state (hash)])
  (->* (majordomo? task-proc/c) (any/c) task?)

  (define majordomo-cust (majordomo.cust jarvis))

  ; create a manager thread, a worker thread, and a task struct, then update jarvis
  (parameterize ([current-custodian majordomo-cust])
    (define manager-cust (make-custodian)) ; created as subordinate of majordomo-cust
    (parameterize ([current-custodian manager-cust])
      ; task++ creates a custodian.  It will be a subordinate of manager-cust
      (define the-task     (task++ #:proc proc
                                   #:data initial-state
                                   #:manager-cust manager-cust))
      (define worker-thd   (make-worker-thread  the-task))
      (define manager-thd  (make-manager-thread (set-task-worker-thd the-task worker-thd)))
      the-task)))

;;----------------------------------------------------------------------

(define/contract (make-worker-thread the-task)
  (-> task? thread?)
  (thread
   (thunk
    (parameterize ([current-custodian (task.worker-cust the-task)])
      ((task.proc the-task) the-task)))))

;;----------------------------------------------------------------------

(define/contract (make-manager-thread the-task)
  (-> task? thread?)
  (thread
   (thunk
    (define manager-ch    (task.manager-ch   the-task))
    (define customer-ch   (task.customer-ch   the-task))
    ; manager-ch  allows the task to send messages to this thread
    ; customer-ch allows this thread to send messages to the thread that submitted the job

    (let loop ([current    the-task])
      (define current-data (task.data current))
      (define worker-thd   (task.worker-thd current))
      (match (sync/timeout (task-timeout) manager-ch worker-thd)
        ; Is the task complete?
        [(and (struct* task ([status (or 'succeeded 'failed)])) msg)
         (async-channel-put customer-ch msg)
         (custodian-shutdown-all (task.worker-cust current))]
        ;
        ; Is it a data update?
        [(and (not #f) (not (== worker-thd)) (not (? task?)) updated-data)
         (loop (set-task-data current updated-data))]
        ;
        ; Did the task time out?. If so, shut down resources from prior run and restart
        [#f
         (custodian-shutdown-all (task.worker-cust current))
         
         (define updated-task (set-task-worker-cust current (make-custodian)))
         (define worker-thd   (make-worker-thread updated-task))
         (loop (set-task-worker-thd updated-task worker-thd))]
        ;
        ; Did the user incorrectly send us an incomplete task?
        [(? task? msg)
         (raise-arguments-error 'majordomo-processor
                                "A task-processing function messaged its manager with an incomplete task.  Only legal values are a succeeded/failed task (will be returned to customer), #f (restarts the task), or a data update (anything else that is not an incomplete task or #f)"
                                "task id"          (task.id current)
                                "task data"        (task.data current)
                                "invalid message"  msg)]
        ;
        [(== worker-thd)
         ;    Usually when we match the worker thread it means that the thread errored out
         ;    or simply ended.  On the other hand, when syncing on two events it's
         ;    possible for both of them to come ready at the same time.  If that happens,
         ;    Racket chooses pseudo-randomly which one to use.  Therefore, it's possible
         ;    that the thread sent us its final value, exited, and Racket chose the thread
         ;    instead of the message.  Check the channel one last time and wrap up based
         ;    on the results.
         (custodian-shutdown-all (task.worker-cust current))
         ; drain all remaining messages from the channel, get the last one (should be most
         ; current)
         (define remaining-msgs
           (for/list ([msg (in-producer (lambda () (async-channel-try-get manager-ch)) #f)])
             msg))
         (define final-msg
           (if (null? remaining-msgs)
               #f
               (first (reverse remaining-msgs))))

         (define failed-task (set-task-status current 'failed ))
         (async-channel-put customer-ch
                            (match final-msg
                              [#f                  failed-task]
                              [(and (struct* task ([status (or 'succeeded 'failed)])) msg)
                               msg]
                              [(? task? msg)       (set-task-status msg 'failed)]
                              [(and (not #f) data) (set-task-data failed-task data)]))])))))

