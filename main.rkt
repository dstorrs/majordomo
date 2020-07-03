#lang racket

(require racket/async-channel
         racket/splicing
         struct-plus-plus)

(module+ test
  (require rackunit))

;;----------------------------------------------------------------------

(provide start-majordomo
         stop-majordomo
         majordomo?
         majordomo-in-ch
         majordomo-out-ch
         majordomo.in-ch
         majordomo.out-ch
         )

(struct++ majordomo
          ([(cust   (make-custodian))     custodian?]
           [(in-ch  (make-async-channel)) async-channel?]
           [(out-ch (make-async-channel)) async-channel?]))

(define (start-majordomo)
  (-> majordomo?)
  (define self (majordomo++))
  (parameterize ([current-custodian (majordomo.cust self)])
    'ok
    )
  self)

(define/contract (stop-majordomo md)
  (-> majordomo? any)
  (custodian-shutdown-all (majordomo.cust md)))
