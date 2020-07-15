#lang racket

(require racket/async-channel
         racket/splicing
         struct-plus-plus
         "messages.rkt"
         "private/task.rkt"
         )

;;----------------------------------------------------------------------

(provide start-majordomo
         stop-majordomo

         start-task

         majordomo?
         majordomo-id       majordomo.id

         ; Parameters
         task-timeout ; (or/c #f (and/c real? (not/c negative?)) (-> any))
         max-restarts ; natural-number/c

         ; Provide only the public-facing accessors and functions
         task-proc        task.proc
         task-id          task.id
         task-status      task.status
         task-data        task.data
         task-num-restarts task.num-restarts
         tell-manager
         set-task-status
         set-task-data

         finalize

         (all-from-out "messages.rkt"))

;;----------------------------------------------------------------------

(struct++ majordomo
          ([(id    (gensym "majordomo-"))  symbol?]  ; makes it human-identifiable
           [(cust  (make-custodian))       custodian?]))

;;
;;----------------------------------------------------------------------

(define (start-majordomo)
  (majordomo++))

;;----------------------------------------------------------------------

(define/contract (stop-majordomo jarvis)
  (-> majordomo? any)
  (custodian-shutdown-all (majordomo.cust jarvis)))

;;----------------------------------------------------------------------

(define/contract (start-task jarvis proc [initial-state (hash)]
                             #:cleanup   [cleanup (λ (the-task) 'do-nothing)])
  (->* (majordomo? task-proc/c)
       (any/c #:cleanup (-> task? any))
       (values task? async-channel?))

  (define majordomo-cust (majordomo.cust jarvis))

  ; create a manager thread, a worker thread, and a task struct, then update jarvis
  (parameterize ([current-custodian majordomo-cust])
    (define manager-cust (make-custodian)) ; created as subordinate of majordomo-cust
    (parameterize ([current-custodian manager-cust])
      ; task++ creates a custodian.  It will be a subordinate of manager-cust
      (define the-task     (task++ #:proc         proc
                                   #:data         initial-state
                                   #:manager-cust manager-cust
                                   #:cleanup      cleanup))
      (define worker-thd   (make-worker-thread  the-task))
      (define manager-thd  (make-manager-thread (set-task-worker-thd the-task worker-thd)))

      ; No one outside this module has the accesor for customer-ch so we must return it
      ; separately.  The intent is to prevent tasks from messaging their customers
      ; directly, since that would make it more likely for them to not finalize properly.
      (values the-task (task.customer-ch the-task)))))

;;----------------------------------------------------------------------

(define/contract (tell-manager the-task msg)
  (-> task? any/c any)
  (async-channel-put (task.manager-ch the-task) msg))

;;----------------------------------------------------------------------

(define/contract (tell-customer the-task msg)
  (-> task? any/c any)
  (async-channel-put (task.customer-ch the-task) msg))

;;----------------------------------------------------------------------

(define/contract (keepalive the-task)
  (-> task? any)
  (tell-manager the-task 'keepalive))

;;----------------------------------------------------------------------

(define/contract (finalize the-task status)
  (-> task? (or/c 'succeeded 'failed) task?)
  (define updated-task  (set-task-status the-task status))
  (tell-manager the-task updated-task)
  updated-task)

;;----------------------------------------------------------------------

(define (restart-task the-task exn-ctor)
  (custodian-shutdown-all (task.worker-cust the-task))

  (define num-restarts  (task.num-restarts the-task))
  (define updated-task (set-task-worker-cust the-task (make-custodian)))
  (define worker-thd   (make-worker-thread updated-task))
  (define restarted (set-task-num-restarts
                     (set-task-worker-thd updated-task worker-thd)
                     (add1 num-restarts)))
  (tell-customer restarted (exn-ctor restarted))
  restarted)

;;----------------------------------------------------------------------

(define (get-latest-message manager-ch)
  ; drain all remaining messages from the channel, get the last one (should be most
  ; current)
  (define remaining-msgs
    (for/list ([msg (in-producer (lambda () (async-channel-try-get manager-ch)) #f)])
      msg))
  (if (null? remaining-msgs)
      #f
      (first (reverse remaining-msgs))))

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

    (let loop ([current      the-task])
      (define current-data (task.data current))
      (define worker-thd   (task.worker-thd current))
      (match (sync/timeout (task-timeout) manager-ch worker-thd)
        ; Is this a keepalive?
        ['keepalive (loop current)]
        ;
        ; Is the task complete?
        [(? task? msg)
         ((task.cleanup the-task) the-task)
         (custodian-shutdown-all (task.worker-cust current))
         (tell-customer the-task msg)]
        ;
        ; Is it a data update?
        [(and (not #f) (not (== worker-thd)) updated-data)
         (loop (set-task-data current updated-data))]
        ;
        ; Did the task time out with restarts left to go?
        ; If so, shut down resources from prior run and restart
        [#f
         #:when (<= (task.num-restarts current) (max-restarts))
         (loop (restart-task current make-task-msg:restart:timeout))]
        ;
        ; Did the task time out when there were no restarts left?  If so, report failure
        [#f
         (tell-customer the-task (set-task-status current 'failed))
         (custodian-shutdown-all (task.worker-cust current))]
        ;
        ;  Did the worker thread end (either due to error or completion) and we have
        ;  restarts left?
        [(== worker-thd)
         #:when (<= (task.num-restarts current) (max-restarts))
         (define latest-msg (get-latest-message manager-ch))
         (match latest-msg
           [(? task? msg) (tell-customer the-task msg)]
           [(and (not #f) data)
            (loop (restart-task (set-task-data current data)
                                make-task-msg:restart:worker-thread))]
           [#f (loop (restart-task current make-task-msg:restart:worker-thread))])]
        ;
        ; Did the worker thread end when there were NOT restarts left?
        [(== worker-thd)
         ;    Usually when we match the worker thread it means that the thread errored out
         ;    or simply ended.  On the other hand, when syncing on two events it's
         ;    possible for both of them to come ready at the same time.  If that happens,
         ;    Racket chooses pseudo-randomly which one to use.  Therefore, it's possible
         ;    that the thread sent us its final value, exited, and Racket chose the thread
         ;    instead of the message.  Check the channel one last time and wrap up based
         ;    on the results.
         (custodian-shutdown-all (task.worker-cust current))
         (define latest-msg (get-latest-message manager-ch))
         (define failed-task (set-task-status current 'failed))
         (tell-customer current (match latest-msg
                                  [(? task? msg)       msg]
                                  [(or #f 'keepalive)  failed-task]
                                  [data (set-task-data failed-task data)]))])))))
