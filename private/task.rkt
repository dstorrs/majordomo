#lang racket/base

(require racket/async-channel
         racket/contract/base
         racket/contract/region
         racket/function
         struct-plus-plus)

(provide (all-defined-out))

(define/contract task-timeout
  (parameter/c (or/c #f (and/c real? (not/c negative?))))
  (make-parameter 5))

(define/contract max-restarts
  (parameter/c natural-number/c)
  (make-parameter 5))

(struct++ task
          ([proc                                  (-> task? any)]
           [manager-cust                          custodian?]
           [cleanup                               (-> task? any)]
           [(id     (gensym "task-"))             symbol?]
           [(status 'incomplete)                  (or/c 'incomplete 'succeeded 'failed)]
           [(data   (hash))                       any/c]
           [(manager-ch  (make-manager-ch))       async-channel?]
           [(num-restarts 0)                      natural-number/c]
           ;
           ;  These fields are private
           [(customer-ch (make-async-channel))    async-channel?]
           [(worker-thd  #f)                      (or/c #f thread?)]
           [(worker-cust (make-custodian))        custodian?])
          #:transparent)

(define (make-manager-ch)
  (define/contract ch
    (async-channel/c (or/c (negate task?)
                           (λ (t)
                             (or (equal? (task.status t) 'succeeded)
                                 (equal? (task.status t) 'failed)))))
    (make-async-channel))
  ch)

(define task-proc/c (-> task? any))
