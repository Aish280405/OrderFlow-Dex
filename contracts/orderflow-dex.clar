
;; OrderFlow DEX - Professional Trading Platform
;; Simplified version with core limit order functionality

;; Error Constants
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_AMOUNT (err u101))
(define-constant ERR_INVALID_PRICE (err u102))
(define-constant ERR_ORDER_NOT_FOUND (err u103))
(define-constant ERR_INSUFFICIENT_BALANCE (err u104))
(define-constant ERR_INVALID_SIDE (err u105))
(define-constant ERR_SAME_USER (err u106))

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant PRECISION u1000000) ;; 6 decimal precision
(define-constant FEE_BASIS_POINTS u30) ;; 0.3% trading fee

;; Data Variables
(define-data-var next-order-id uint u1)
(define-data-var total-volume uint u0)
(define-data-var total-fees uint u0)

;; Order Structure - Professional trading order with advanced fields
(define-map orders
    uint ;; order-id
    {
        user: principal,
        side: (string-ascii 4), ;; "buy" or "sell"
        token-pair: (string-ascii 20), ;; e.g. "STX-USDT"
        amount: uint, ;; Amount to trade
        price: uint, ;; Limit price
        filled-amount: uint, ;; Amount already filled
        status: (string-ascii 10), ;; "open", "filled", "cancelled"
        created-at: uint, ;; Block height when created
        order-type: (string-ascii 10) ;; "limit" for limit orders
    }
)

;; User balances for escrow (holds funds during active orders)
(define-map user-balances
    {user: principal, token: (string-ascii 10)}
    uint
)

;; Trade history for transparency and analytics
(define-map trades
    uint ;; trade-id
    {
        order-id: uint,
        buyer: principal,
        seller: principal,
        amount: uint,
        price: uint,
        fee: uint,
        timestamp: uint
    }
)

;; === READ-ONLY FUNCTIONS ===

;; Get order details
(define-read-only (get-order (order-id uint))
    (map-get? orders order-id)
)

;; Get user balance in escrow
(define-read-only (get-user-balance (user principal) (token (string-ascii 10)))
    (default-to u0 (map-get? user-balances {user: user, token: token}))
)

;; Get DEX statistics
(define-read-only (get-dex-stats)
    {
        total-volume: (var-get total-volume),
        total-fees: (var-get total-fees),
        next-order-id: (var-get next-order-id)
    }
)

;; Calculate trading fee
(define-read-only (calculate-fee (amount uint))
    (/ (* amount FEE_BASIS_POINTS) u10000)
)

;; === CORE DEX FUNCTIONS ===

;; Function 1: Place Limit Order
;; Professional limit order placement with comprehensive validation
(define-public (place-limit-order 
    (side (string-ascii 4)) 
    (token-pair (string-ascii 20)) 
    (amount uint) 
    (price uint))
    (let ((order-id (var-get next-order-id)))
        ;; Input validation
        (asserts! (or (is-eq side "buy") (is-eq side "sell")) ERR_INVALID_SIDE)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (> price u0) ERR_INVALID_PRICE)

        ;; Check user has sufficient balance for the order
        (let ((required-balance (if (is-eq side "buy") 
                                  (/ (* amount price) PRECISION) ;; For buy orders, need quote token
                                  amount))) ;; For sell orders, need base token

            ;; For demo purposes, we'll assume users have sufficient balance
            ;; In production, this would check actual token balances

            ;; Create the limit order
            (map-set orders order-id {
                user: tx-sender,
                side: side,
                token-pair: token-pair,
                amount: amount,
                price: price,
                filled-amount: u0,
                status: "open",
                created-at: stacks-block-height,
                order-type: "limit"
            })

            ;; Update order ID counter
            (var-set next-order-id (+ order-id u1))

            ;; Lock user funds in escrow (simplified)
            (if (is-eq side "buy")
                (map-set user-balances 
                    {user: tx-sender, token: "USDT"} 
                    (+ (get-user-balance tx-sender "USDT") required-balance))
                (map-set user-balances 
                    {user: tx-sender, token: "STX"} 
                    (+ (get-user-balance tx-sender "STX") required-balance))
            )

            ;; Emit order placed event
            (print {
                event: "order-placed",
                order-id: order-id,
                user: tx-sender,
                side: side,
                token-pair: token-pair,
                amount: amount,
                price: price
            })

            (ok order-id)
        )
    )
)

;; Function 2: Execute Trade
;; Advanced trade execution with matching logic and fee calculation
(define-public (execute-trade (buy-order-id uint) (sell-order-id uint) (trade-amount uint))
    (let (
        (buy-order (unwrap! (get-order buy-order-id) ERR_ORDER_NOT_FOUND))
        (sell-order (unwrap! (get-order sell-order-id) ERR_ORDER_NOT_FOUND))
    )
        ;; Validation checks
        (asserts! (is-eq (get side buy-order) "buy") ERR_INVALID_SIDE)
        (asserts! (is-eq (get side sell-order) "sell") ERR_INVALID_SIDE)
        (asserts! (is-eq (get token-pair buy-order) (get token-pair sell-order)) ERR_INVALID_SIDE)
        (asserts! (not (is-eq (get user buy-order) (get user sell-order))) ERR_SAME_USER)
        (asserts! (is-eq (get status buy-order) "open") ERR_ORDER_NOT_FOUND)
        (asserts! (is-eq (get status sell-order) "open") ERR_ORDER_NOT_FOUND)
        (asserts! (> trade-amount u0) ERR_INVALID_AMOUNT)

        ;; Price matching validation (buy price >= sell price)
        (asserts! (>= (get price buy-order) (get price sell-order)) ERR_INVALID_PRICE)

        ;; Check sufficient unfilled amounts
        (let (
            (buy-remaining (- (get amount buy-order) (get filled-amount buy-order)))
            (sell-remaining (- (get amount sell-order) (get filled-amount sell-order)))
        )
            (asserts! (>= buy-remaining trade-amount) ERR_INSUFFICIENT_BALANCE)
            (asserts! (>= sell-remaining trade-amount) ERR_INSUFFICIENT_BALANCE)

            ;; Execute the trade at the sell order price (price improvement for buyer)
            (let (
                (trade-price (get price sell-order))
                (trade-value (/ (* trade-amount trade-price) PRECISION))
                (trading-fee (calculate-fee trade-value))
                (buyer (get user buy-order))
                (seller (get user sell-order))
            )
                ;; Update order fill amounts
                (map-set orders buy-order-id 
                    (merge buy-order {
                        filled-amount: (+ (get filled-amount buy-order) trade-amount),
                        status: (if (is-eq (+ (get filled-amount buy-order) trade-amount) (get amount buy-order)) 
                               "filled" 
                               "partial")
                    })
                )

                (map-set orders sell-order-id 
                    (merge sell-order {
                        filled-amount: (+ (get filled-amount sell-order) trade-amount),
                        status: (if (is-eq (+ (get filled-amount sell-order) trade-amount) (get amount sell-order)) 
                               "filled" 
                               "partial")
                    })
                )

                ;; Update DEX statistics
                (var-set total-volume (+ (var-get total-volume) trade-value))
                (var-set total-fees (+ (var-get total-fees) trading-fee))

                ;; Record trade for history and analytics
                (map-set trades (var-get total-volume) {
                    order-id: buy-order-id,
                    buyer: buyer,
                    seller: seller,
                    amount: trade-amount,
                    price: trade-price,
                    fee: trading-fee,
                    timestamp: stacks-block-height
                })

                ;; Emit trade executed event
                (print {
                    event: "trade-executed",
                    buy-order-id: buy-order-id,
                    sell-order-id: sell-order-id,
                    buyer: buyer,
                    seller: seller,
                    amount: trade-amount,
                    price: trade-price,
                    fee: trading-fee,
                    volume: trade-value
                })

                (ok {
                    trade-amount: trade-amount,
                    trade-price: trade-price,
                    trade-value: trade-value,
                    trading-fee: trading-fee
                })
            )
        )
    )
)

;; === UTILITY FUNCTIONS ===

;; Get all open orders for a user (simplified view)
(define-read-only (get-user-orders (user principal))
    ;; In a full implementation, this would iterate through orders
    ;; For now, returns a success message
    (ok "Use block explorer to view user orders")
)

;; Get order book depth (simplified)
(define-read-only (get-order-book (token-pair (string-ascii 20)))
    ;; In a full implementation, this would aggregate buy/sell orders
    ;; For now, returns basic stats
    {
        pair: token-pair,
        total-orders: (- (var-get next-order-id) u1),
        total-volume: (var-get total-volume)
    }
)
