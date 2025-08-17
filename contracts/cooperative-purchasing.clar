;; Cooperative Purchasing Contract
;; Facilitates group buying initiatives and bulk equipment orders

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-ORDER-NOT-FOUND (err u401))
(define-constant ERR-ORDER-CLOSED (err u402))
(define-constant ERR-ALREADY-PARTICIPATED (err u403))
(define-constant ERR-INSUFFICIENT-PARTICIPANTS (err u404))
(define-constant ERR-INVALID-INPUT (err u405))

;; Data Variables
(define-data-var next-order-id uint u1)

;; Data Maps
(define-map cooperative-orders
  { order-id: uint }
  {
    organizer: principal,
    equipment-type: (string-ascii 50),
    model: (string-ascii 50),
    target-quantity: uint,
    current-quantity: uint,
    unit-price: uint,
    bulk-discount-rate: uint,
    minimum-participants: uint,
    maximum-participants: uint,
    deadline: uint,
    status: (string-ascii 20),
    created-at: uint
  }
)

(define-map order-participants
  { order-id: uint, participant: principal }
  {
    quantity-requested: uint,
    contribution-amount: uint,
    payment-status: (string-ascii 20),
    joined-at: uint
  }
)

(define-map order-participant-list
  { order-id: uint }
  { participants: (list 100 principal) }
)

(define-map user-order-history
  { user: principal }
  { order-ids: (list 50 uint) }
)

(define-map order-financials
  { order-id: uint }
  {
    total-collected: uint,
    total-required: uint,
    bulk-savings: uint,
    distribution-complete: bool
  }
)

;; Public Functions

;; Create cooperative order
(define-public (create-cooperative-order
  (equipment-type (string-ascii 50))
  (model (string-ascii 50))
  (target-quantity uint)
  (unit-price uint)
  (bulk-discount-rate uint)
  (minimum-participants uint)
  (maximum-participants uint)
  (deadline uint))
  (let
    (
      (order-id (var-get next-order-id))
      (current-user-history (default-to { order-ids: (list) }
        (map-get? user-order-history { user: tx-sender })))
    )
    ;; Validate input
    (asserts! (> (len equipment-type) u0) ERR-INVALID-INPUT)
    (asserts! (> (len model) u0) ERR-INVALID-INPUT)
    (asserts! (> target-quantity u0) ERR-INVALID-INPUT)
    (asserts! (> unit-price u0) ERR-INVALID-INPUT)
    (asserts! (<= bulk-discount-rate u100) ERR-INVALID-INPUT)
    (asserts! (> minimum-participants u1) ERR-INVALID-INPUT)
    (asserts! (>= maximum-participants minimum-participants) ERR-INVALID-INPUT)
    (asserts! (> deadline block-height) ERR-INVALID-INPUT)

    ;; Create order
    (map-set cooperative-orders
      { order-id: order-id }
      {
        organizer: tx-sender,
        equipment-type: equipment-type,
        model: model,
        target-quantity: target-quantity,
        current-quantity: u0,
        unit-price: unit-price,
        bulk-discount-rate: bulk-discount-rate,
        minimum-participants: minimum-participants,
        maximum-participants: maximum-participants,
        deadline: deadline,
        status: "open",
        created-at: block-height
      }
    )

    ;; Initialize participant list
    (map-set order-participant-list
      { order-id: order-id }
      { participants: (list) }
    )

    ;; Initialize financials
    (map-set order-financials
      { order-id: order-id }
      {
        total-collected: u0,
        total-required: (* target-quantity unit-price),
        bulk-savings: u0,
        distribution-complete: false
      }
    )

    ;; Update user order history
    (map-set user-order-history
      { user: tx-sender }
      { order-ids: (unwrap! (as-max-len?
        (append (get order-ids current-user-history) order-id) u50)
        ERR-INVALID-INPUT) }
    )

    ;; Increment next ID
    (var-set next-order-id (+ order-id u1))

    (ok order-id)
  )
)

;; Join cooperative order
(define-public (join-cooperative-order
  (order-id uint)
  (quantity-requested uint))
  (let
    (
      (order (unwrap! (map-get? cooperative-orders { order-id: order-id })
        ERR-ORDER-NOT-FOUND))
      (participant-list (unwrap! (map-get? order-participant-list { order-id: order-id })
        ERR-ORDER-NOT-FOUND))
      (contribution-amount (* quantity-requested (get unit-price order)))
      (current-user-history (default-to { order-ids: (list) }
        (map-get? user-order-history { user: tx-sender })))
    )
    ;; Validate order status
    (asserts! (is-eq (get status order) "open") ERR-ORDER-CLOSED)
    (asserts! (< block-height (get deadline order)) ERR-ORDER-CLOSED)

    ;; Check not already participated
    (asserts! (is-none (map-get? order-participants { order-id: order-id, participant: tx-sender }))
      ERR-ALREADY-PARTICIPATED)

    ;; Validate input
    (asserts! (> quantity-requested u0) ERR-INVALID-INPUT)
    (asserts! (< (len (get participants participant-list)) (get maximum-participants order))
      ERR-INVALID-INPUT)

    ;; Add participant
    (map-set order-participants
      { order-id: order-id, participant: tx-sender }
      {
        quantity-requested: quantity-requested,
        contribution-amount: contribution-amount,
        payment-status: "pending",
        joined-at: block-height
      }
    )

    ;; Update participant list
    (map-set order-participant-list
      { order-id: order-id }
      { participants: (unwrap! (as-max-len?
        (append (get participants participant-list) tx-sender) u100)
        ERR-INVALID-INPUT) }
    )

    ;; Update order quantity
    (map-set cooperative-orders
      { order-id: order-id }
      (merge order { current-quantity: (+ (get current-quantity order) quantity-requested) })
    )

    ;; Update user order history
    (map-set user-order-history
      { user: tx-sender }
      { order-ids: (unwrap! (as-max-len?
        (append (get order-ids current-user-history) order-id) u50)
        ERR-INVALID-INPUT) }
    )

    (ok true)
  )
)

;; Process payment for cooperative order
(define-public (pay-cooperative-order
  (order-id uint)
  (payment-amount uint))
  (let
    (
      (order (unwrap! (map-get? cooperative-orders { order-id: order-id })
        ERR-ORDER-NOT-FOUND))
      (participation (unwrap! (map-get? order-participants { order-id: order-id, participant: tx-sender })
        ERR-NOT-AUTHORIZED))
      (financials (unwrap! (map-get? order-financials { order-id: order-id })
        ERR-ORDER-NOT-FOUND))
    )
    ;; Validate payment
    (asserts! (is-eq payment-amount (get contribution-amount participation)) ERR-INVALID-INPUT)
    (asserts! (is-eq (get payment-status participation) "pending") ERR-NOT-AUTHORIZED)

    ;; Update payment status
    (map-set order-participants
      { order-id: order-id, participant: tx-sender }
      (merge participation { payment-status: "paid" })
    )

    ;; Update financials
    (map-set order-financials
      { order-id: order-id }
      (merge financials
        { total-collected: (+ (get total-collected financials) payment-amount) })
    )

    (ok true)
  )
)

;; Finalize cooperative order
(define-public (finalize-cooperative-order (order-id uint))
  (let
    (
      (order (unwrap! (map-get? cooperative-orders { order-id: order-id })
        ERR-ORDER-NOT-FOUND))
      (participant-list (unwrap! (map-get? order-participant-list { order-id: order-id })
        ERR-ORDER-NOT-FOUND))
      (participant-count (len (get participants participant-list)))
    )
    ;; Check authorization
    (asserts! (is-eq tx-sender (get organizer order)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status order) "open") ERR-ORDER-CLOSED)

    ;; Check minimum participants
    (asserts! (>= participant-count (get minimum-participants order)) ERR-INSUFFICIENT-PARTICIPANTS)

    ;; Update order status
    (map-set cooperative-orders
      { order-id: order-id }
      (merge order { status: "finalized" })
    )

    (ok true)
  )
)

;; Read-only Functions

;; Get cooperative order details
(define-read-only (get-cooperative-order (order-id uint))
  (map-get? cooperative-orders { order-id: order-id })
)

;; Get order participants
(define-read-only (get-order-participants (order-id uint))
  (map-get? order-participant-list { order-id: order-id })
)

;; Get participant details
(define-read-only (get-participant-details (order-id uint) (participant principal))
  (map-get? order-participants { order-id: order-id, participant: participant })
)

;; Get order financials
(define-read-only (get-order-financials (order-id uint))
  (map-get? order-financials { order-id: order-id })
)

;; Get user order history
(define-read-only (get-user-order-history (user principal))
  (map-get? user-order-history { user: user })
)

;; Calculate bulk savings
(define-read-only (calculate-bulk-savings (order-id uint))
  (match (map-get? cooperative-orders { order-id: order-id })
    order-data
      (let
        (
          (total-cost (* (get current-quantity order-data) (get unit-price order-data)))
          (discount-amount (/ (* total-cost (get bulk-discount-rate order-data)) u100))
        )
        (some discount-amount)
      )
    none
  )
)
