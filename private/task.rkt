#lang racket/base

(require racket/async-channel
         racket/contract/base
         struct-plus-plus)

(provide (all-defined-out))

(define task-timeout (make-parameter 5))

(struct++ task
          ([proc                          (-> task? any)]
           [manager-cust                  custodian?]
           [(id     (gensym "task-"))     symbol?]
           [(status 'incomplete)          (or/c 'incomplete 'succeeded 'failed)]
           [(data   (hash))               any/c]
           ;
           ;  These fields are private
           [(worker-thd  #f)                      (or/c #f thread?)]
           [(manager-ch  (make-async-channel))    async-channel?]
           [(customer-ch (make-async-channel))    async-channel?]
           [(worker-cust (make-custodian))        custodian?]
           )
          #:transparent
          )

(define task-proc/c (-> task? any))
