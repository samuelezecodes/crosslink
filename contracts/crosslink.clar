;; CrossLink: Multi-Chain Bridge Contract
;; Facilitates secure token transfers between different blockchain networks

(use-trait token-trait .token-trait.token-trait)

;; Error codes
(define-constant ERR-BRIDGE-EXPIRED (err u1))
(define-constant ERR-BRIDGE-NOT-FOUND (err u2))
(define-constant ERR-UNAUTHORIZED (err u3))
(define-constant ERR-BRIDGE-COMPLETED (err u4))
(define-constant ERR-INVALID-AMOUNT (err u5))
(define-constant ERR-INSUFFICIENT-BALANCE (err u6))
(define-constant ERR-INVALID-TOKEN (err u7))
(define-constant ERR-INVALID-SECRET (err u8))
(define-constant ERR-INVALID-CHAIN (err u9))
(define-constant ERR-INVALID-RECIPIENT (err u10))

;; Constants for validation
(define-constant CHAIN-NAME-MAX-LENGTH u8)
(define-constant RECIPIENT-ADDRESS-MAX-LENGTH u42)
(define-constant MIN-LOCK-PERIOD u1)
(define-constant MAX-LOCK-PERIOD u1440)
(define-constant SECRET-HASH-LENGTH u32)
(define-constant MAX-TOKEN-AMOUNT u340282366920938463463374607431768211455)

;; Data storage
(define-map bridge-operations
  { bridge-id: (buff 32) }
  {
    initiator: principal,
    counterparty: (optional principal),
    token-contract: principal,
    amount: uint,
    secret-hash: (buff 32),
    expiry-block: uint,
    status: (string-ascii 20),
    target-chain: (string-ascii 8),
    recipient-address: (string-ascii 42)
  }
)

(define-data-var operation-counter uint u0)

;; Read-only functions
(define-read-only (get-bridge-details (bridge-id (buff 32)))
  (map-get? bridge-operations { bridge-id: bridge-id })
)

(define-read-only (verify-secret (provided-secret (buff 32)) (stored-hash (buff 32)))
  (is-eq (sha256 provided-secret) stored-hash)
)

;; Validation functions
(define-private (validate-token (token <token-trait>))
  (let 
    (
      (contract-principal (contract-of token))
    )
    (match (contract-call? token get-name)
      success (ok contract-principal)
      error ERR-INVALID-TOKEN)))

(define-private (validate-secret-hash (hash (buff 32)))
  (begin
    (asserts! (is-eq (len hash) SECRET-HASH-LENGTH) ERR-INVALID-SECRET)
    (asserts! (not (is-eq hash 0x0000000000000000000000000000000000000000000000000000000000000000)) ERR-INVALID-SECRET)
    (ok hash)))

(define-private (validate-chain-name (chain-name (string-ascii 8)))
  (begin
    (asserts! (and 
      (>= (len chain-name) u1) 
      (<= (len chain-name) CHAIN-NAME-MAX-LENGTH)
    ) ERR-INVALID-CHAIN)
    (asserts! (is-some (index-of (list "bitcoin" "ethereum" "stacks") chain-name)) ERR-INVALID-CHAIN)
    (ok chain-name)))

(define-private (validate-recipient (address (string-ascii 42)))
  (begin
    (asserts! (and 
      (>= (len address) u1) 
      (<= (len address) RECIPIENT-ADDRESS-MAX-LENGTH)
    ) ERR-INVALID-RECIPIENT)
    
    (let ((address-prefix (unwrap! (slice? address u0 u2) ERR-INVALID-RECIPIENT)))
      (asserts! (is-some (index-of (list (convert-prefix "0x") 
                                        (convert-prefix "bc") 
                                        (convert-prefix "SP")) 
                                  (convert-prefix address-prefix))) 
               ERR-INVALID-RECIPIENT))
    
    (ok address)))

(define-private (convert-prefix (s (string-ascii 42)))
  (unwrap-panic (slice? s u0 u2)))

(define-private (validate-amount (amount uint))
  (begin
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (<= amount MAX-TOKEN-AMOUNT) ERR-INVALID-AMOUNT)
    (ok amount)))

(define-private (validate-lock-period (period uint))
  (begin
    (asserts! (>= period MIN-LOCK-PERIOD) ERR-INVALID-AMOUNT)
    (asserts! (<= period MAX-LOCK-PERIOD) ERR-INVALID-AMOUNT)
    (ok period)))

(define-private (calculate-expiry (current-height uint) (period uint))
  (begin
    (let ((expiry (+ current-height period)))
      (asserts! (<= expiry MAX-TOKEN-AMOUNT) ERR-INVALID-AMOUNT)
      (ok expiry))))

;; Helper function
(define-private (generate-bridge-id)
  (sha256 (concat 
    (unwrap-panic (to-consensus-buff? (var-get operation-counter)))
    (unwrap-panic (to-consensus-buff? block-height))
  )))

;; Public functions
(define-public (create-bridge
    (token <token-trait>)
    (amount uint)
    (secret-hash (buff 32))
    (lock-period uint)
    (target-chain (string-ascii 8))
    (recipient-address (string-ascii 42)))
  (let
    (
      (bridge-id (generate-bridge-id))
      (sender tx-sender)
      (current-height block-height)
    )
    ;; Validate all inputs
    (let 
      (
        (valid-amount (try! (validate-amount amount)))
        (valid-period (try! (validate-lock-period lock-period)))
        (valid-token (try! (validate-token token)))
        (valid-hash (try! (validate-secret-hash secret-hash)))
        (valid-chain (try! (validate-chain-name target-chain)))
        (valid-recipient (try! (validate-recipient recipient-address)))
        (valid-expiry (try! (calculate-expiry current-height valid-period)))
      )
      
      ;; Check token balance
      (let
        (
          (sender-balance (unwrap! (contract-call? token get-balance sender) 
                                  ERR-INSUFFICIENT-BALANCE))
        )
        (asserts! (>= sender-balance valid-amount) ERR-INSUFFICIENT-BALANCE)
        
        ;; Transfer tokens to contract
        (try! (contract-call? token transfer 
          valid-amount
          sender
          (as-contract tx-sender)
          none))
        
        ;; Create bridge record
        (map-set bridge-operations
          { bridge-id: bridge-id }
          {
            initiator: sender,
            counterparty: none,
            token-contract: valid-token,
            amount: valid-amount,
            secret-hash: valid-hash,
            expiry-block: valid-expiry,
            status: "pending",
            target-chain: valid-chain,
            recipient-address: valid-recipient
          }
        )
        
        ;; Increment counter
        (var-set operation-counter (+ (var-get operation-counter) u1))
        
        (ok bridge-id)
      )
    )
  ))

(define-public (join-bridge
    (bridge-id (buff 32)))
  (let
    (
      (bridge-details (unwrap! (get-bridge-details bridge-id) ERR-BRIDGE-NOT-FOUND))
      (sender tx-sender)
    )
    ;; Validate bridge state
    (asserts! (is-eq (get status bridge-details) "pending") ERR-BRIDGE-COMPLETED)
    (asserts! (is-none (get counterparty bridge-details)) ERR-BRIDGE-COMPLETED)
    
    ;; Update counterparty
    (map-set bridge-operations
      { bridge-id: bridge-id }
      (merge bridge-details { 
        counterparty: (some sender),
        status: "active"
      })
    )
    
    (ok true)
  ))

(define-public (complete-bridge
    (bridge-id (buff 32))
    (secret (buff 32))
    (token <token-trait>))
  (let
    (
      (bridge-details (unwrap! (get-bridge-details bridge-id) ERR-BRIDGE-NOT-FOUND))
      (participant (unwrap! (get counterparty bridge-details) ERR-UNAUTHORIZED))
      (valid-token (try! (validate-token token)))
      (current-height block-height)
    )
    ;; Validate bridge state
    (asserts! (is-eq (get status bridge-details) "active") ERR-BRIDGE-COMPLETED)
    (asserts! (< current-height (get expiry-block bridge-details)) ERR-BRIDGE-EXPIRED)
    (asserts! (verify-secret secret (get secret-hash bridge-details)) ERR-UNAUTHORIZED)
    (asserts! (is-eq valid-token (get token-contract bridge-details)) ERR-INVALID-TOKEN)
    
    ;; Transfer tokens to participant
    (try! (as-contract (contract-call? token transfer
        (get amount bridge-details)
        tx-sender
        participant
        none)))
    
    ;; Update status
    (map-set bridge-operations
      { bridge-id: bridge-id }
      (merge bridge-details { status: "completed" })
    )
    
    (ok true)
  ))

(define-public (reclaim-tokens
    (bridge-id (buff 32))
    (token <token-trait>))
  (let
    (
      (bridge-details (unwrap! (get-bridge-details bridge-id) ERR-BRIDGE-NOT-FOUND))
      (valid-token (try! (validate-token token)))
      (current-height block-height)
    )
    ;; Validate bridge state
    (asserts! (is-eq (get status bridge-details) "pending") ERR-BRIDGE-COMPLETED)
    (asserts! (>= current-height (get expiry-block bridge-details)) ERR-UNAUTHORIZED)
    (asserts! (is-eq tx-sender (get initiator bridge-details)) ERR-UNAUTHORIZED)
    (asserts! (is-eq valid-token (get token-contract bridge-details)) ERR-INVALID-TOKEN)
    
    ;; Transfer tokens back to initiator
    (try! (as-contract (contract-call? token transfer
        (get amount bridge-details)
        tx-sender
        (get initiator bridge-details)
        none)))
    
    ;; Update status
    (map-set bridge-operations
      { bridge-id: bridge-id }
      (merge bridge-details { status: "reclaimed" })
    )
    
    (ok true)
  )))