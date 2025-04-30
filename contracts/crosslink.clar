;; CrossLink: Multi-Chain Bridge Contract
;; Facilitates secure token transfers between different blockchain networks
;; CrossLink Advanced Supply Chain Status Management Contract

;; Enum-like Status Definitions
(define-constant STATUS_REGISTERED "REGISTERED")
(define-constant STATUS_PROCESSING "PROCESSING")
(define-constant STATUS_DISPATCHED "DISPATCHED")
(define-constant STATUS_RECEIVED "RECEIVED")
(define-constant STATUS_COMPROMISED "COMPROMISED")
(define-constant STATUS_MISSING "MISSING")

;; Error Codes for Status Management
(define-constant ERR_INVALID_STATUS_CHANGE (err u200))
(define-constant ERR_UNAUTHORIZED_CHANGE (err u201))
(define-constant ERR_ITEM_NOT_FOUND (err u202))
(define-constant ERR_SENSOR_VERIFICATION_FAILED (err u203))
(define-constant ERR_INVALID_INPUT (err u204))
(define-constant ERR_INVALID_HASH (err u205))
(define-constant ERR_INVALID_SENSOR_DEVICE (err u206))

;; Item Tracking Structure
(define-map inventory
  { item-id: uint }
  {
    custodian: principal,
    current-state: (string-ascii 20),
    producer: principal,
    timestamp: uint,
    sensor-id: (optional (buff 32)),
    verification-hash: (buff 32)
  }
)

;; Status Transition Rules
(define-map state-transitions
  { 
    from-state: (string-ascii 20), 
    to-state: (string-ascii 20) 
  }
  bool
)

;; Sensor Device Verification
(define-map sensor-devices
  { device-id: (buff 32) }
  {
    registered-by: principal,
    is-operational: bool,
    item-id: (optional uint)
  }
)

;; Event Notification Subscriptions
(define-map state-change-subscriptions
  { 
    item-id: uint, 
    subscriber: principal 
  }
  {
    track-states: (list 10 (string-ascii 20))
  }
)

;; Validation Functions
(define-private (validate-hash (hash (buff 32)))
  (> (len hash) u0))

(define-private (validate-sensor-id (device-id (buff 32)))
  (and 
    (> (len device-id) u0)
    (match (map-get? sensor-devices { device-id: device-id })
      device (get is-operational device)
      false)))

;; Initialize Status Transition Rules
(define-public (initialize-state-transitions)
  (begin
    ;; Define valid status transitions
    (map-set state-transitions 
      { from-state: STATUS_REGISTERED, to-state: STATUS_PROCESSING } true)
    (map-set state-transitions 
      { from-state: STATUS_PROCESSING, to-state: STATUS_DISPATCHED } true)
    (map-set state-transitions 
      { from-state: STATUS_DISPATCHED, to-state: STATUS_RECEIVED } true)
    (map-set state-transitions 
      { from-state: STATUS_PROCESSING, to-state: STATUS_COMPROMISED } true)
    (map-set state-transitions 
      { from-state: STATUS_PROCESSING, to-state: STATUS_MISSING } true)
    
    (ok true)
  )
)

;; Helper function to validate status
(define-private (validate-state (state (string-ascii 20)))
  (or 
    (is-eq state STATUS_REGISTERED)
    (is-eq state STATUS_PROCESSING)
    (is-eq state STATUS_DISPATCHED)
    (is-eq state STATUS_RECEIVED)
    (is-eq state STATUS_COMPROMISED)
    (is-eq state STATUS_MISSING)
  )
)

;; Register a New Item with Authenticity Proof
(define-public (register-item
  (item-id uint)
  (producer principal)
  (initial-state (string-ascii 20))
  (verification-hash (buff 32))
  (timestamp uint)
  (optional-sensor-id (optional (buff 32)))
)
  (begin
    ;; Ensure item doesn't already exist
    (asserts! (is-none (map-get? inventory { item-id: item-id })) ERR_ITEM_NOT_FOUND)
    ;; Validate initial status
    (asserts! (validate-state initial-state) ERR_INVALID_INPUT)
    ;; Validate input data
    (asserts! (> item-id u0) ERR_INVALID_INPUT)
    (asserts! (> timestamp u0) ERR_INVALID_INPUT)
    ;; Validate producer
    (asserts! (is-eq tx-sender producer) ERR_UNAUTHORIZED_CHANGE)
    ;; Validate authentication hash
    (asserts! (validate-hash verification-hash) ERR_INVALID_HASH)
    
    ;; Validate optional sensor device if provided
    (asserts! (match optional-sensor-id
                device-id (validate-sensor-id device-id)
                true) 
              ERR_INVALID_SENSOR_DEVICE)
    
    ;; Register item with initial details
    (map-set inventory 
      { item-id: item-id }
      {
        custodian: tx-sender,
        current-state: initial-state,
        producer: producer,
        timestamp: timestamp,
        sensor-id: optional-sensor-id,
        verification-hash: verification-hash
      }
    )
    
    ;; Optional Sensor Device Registration
    (match optional-sensor-id
      device-id 
        (begin
          (asserts! (validate-sensor-id device-id) ERR_INVALID_SENSOR_DEVICE)
          (map-set sensor-devices 
            { device-id: device-id }
            {
              registered-by: tx-sender,
              is-operational: true,
              item-id: (some item-id)
            }
          ))
      true
    )
    
    (ok true)
  )
)

;; Subscribe to Status Change Notifications
(define-public (subscribe-to-state-events
  (item-id uint)
  (track-states (list 10 (string-ascii 20)))
)
  (begin
    ;; Validate item-id
    (asserts! (> item-id u0) ERR_INVALID_INPUT)
    ;; Validate all statuses in the list
    (asserts! (fold check-state track-states true) ERR_INVALID_INPUT)
    
    (map-set state-change-subscriptions 
      { 
        item-id: item-id, 
        subscriber: tx-sender 
      }
      { track-states: track-states }
    )
    (ok true)
  )
)

;; Helper function to check status validity
(define-private (check-state (state (string-ascii 20)) (valid bool))
  (and valid (validate-state state))
)

;; Internal Function to Notify Subscribers
(define-private (notify-state-subscribers
  (item-id uint)
  (new-state (string-ascii 20))
)
  (match 
    (map-get? state-change-subscriptions 
      { 
        item-id: item-id, 
        subscriber: tx-sender 
      }
    )
    subscription
    (if (is-some (index-of (get track-states subscription) new-state))
        (begin
          ;; Future: Implement actual notification mechanism
          (print {
            event: "state-change-notification",
            item-id: item-id,
            state: new-state,
            subscriber: tx-sender
          })
          (ok true)
        )
        (ok false)
    )
    (ok false)
  )
)

;; Sensor Device Registration
(define-public (register-sensor-device
  (device-id (buff 32))
  (item-id (optional uint))
)
  (begin
    ;; Validate device-id
    (asserts! (> (len device-id) u0) ERR_INVALID_SENSOR_DEVICE)
    
    ;; Validate item-id if provided
    (asserts! (match item-id
                id (> id u0)
                true
              ) ERR_INVALID_INPUT)
    
    (map-set sensor-devices 
      { device-id: device-id }
      {
        registered-by: tx-sender,
        is-operational: true,
        item-id: item-id
      }
    )
    (ok true)
  )
)

;; Helper function for batch status processing
(define-private (process-item-state
    (item-id uint)
    (result {
        states: (list 50 {
            item-id: uint,
            state: (optional (string-ascii 20)),
            timestamp: (optional uint)
        }),
        count: uint
    })
)
    (let (
        (item-details (map-get? inventory { item-id: item-id }))
    )
        {
            states: (unwrap-panic 
                (as-max-len? 
                    (concat 
                        (get states result)
                        (list {
                            item-id: item-id,
                            state: (match item-details
                                details (some (get current-state details))
                                none
                            ),
                            timestamp: (match item-details
                                details (some (get timestamp details))
                                none
                            )
                        })
                    )
                    u50
                )
            ),
            count: (+ (get count result) u1)
        }
    )
)