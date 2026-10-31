; unetg_eth.inc -- Ethernet II / ARP / IPv4 / TCP / UDP header offsets
; inside a frame buffer (ctx.scratch for RX, ctx.txh for TX).

	IFNDEF	_UNETG_ETH_INC
	DEFINE	_UNETG_ETH_INC

ETH_DST		EQU	0
ETH_SRC		EQU	6
ETH_TYPE	EQU	12
ETH_HDR		EQU	14
ETH_MIN_FRAME	EQU	60		; without FCS
ETH_MAX_FRAME	EQU	1514

; ARP (at 14)
ARP_HTYPE	EQU	14
ARP_PTYPE	EQU	16
ARP_HLEN	EQU	18
ARP_PLEN	EQU	19
ARP_OP		EQU	20
ARP_SHA		EQU	22
ARP_SPA		EQU	28
ARP_THA		EQU	32
ARP_TPA		EQU	38
ARP_FRAME	EQU	42

; IPv4 (at 14, no options)
ETH_IP		EQU	14
ETH_IP_VIHL	EQU	14
ETH_IP_LEN	EQU	16
ETH_IP_ID	EQU	18
ETH_IP_FRAG	EQU	20
ETH_IP_TTL	EQU	22
ETH_IP_PROTO	EQU	23
ETH_IP_CSUM	EQU	24
ETH_IP_SRC	EQU	26
ETH_IP_DST	EQU	30
IP_HDR		EQU	20
IP_PROTO_TCP	EQU	6
IP_PROTO_UDP	EQU	17

; TCP / UDP (at 34)
ETH_L4		EQU	34
TCP_SPORT	EQU	34
TCP_DPORT	EQU	36
TCP_SEQ		EQU	38
TCP_ACK		EQU	42
TCP_DOFF	EQU	46
TCP_FLAGS	EQU	47
TCP_WND		EQU	48
TCP_CSUM	EQU	50
TCP_URG		EQU	52
TCP_OPT		EQU	54
TCP_HDR		EQU	20
UDP_SPORT	EQU	34
UDP_DPORT	EQU	36
UDP_LEN		EQU	38
UDP_CSUM	EQU	40
UDP_HDR		EQU	8

TCPF_FIN	EQU	0x01
TCPF_SYN	EQU	0x02
TCPF_RST	EQU	0x04
TCPF_PSH	EQU	0x08
TCPF_ACK	EQU	0x10

; Bytes of the transport segment that the first RX portion keeps in
; ctx.scratch (64 - 34); the rest is read from the card in portions.
L4_IN_SCRATCH	EQU	30
RX_HDR_BYTES	EQU	64
NIC_CHUNK	EQU	40		; largest card transfer per DI portion (DI < 200 us)

; Engine state in ctx.hwsm (IX-relative)
HS_PHASE	EQU	0	; u8  card bring-up phase (card specific)
HS_STEP		EQU	1	; u8  sub-step / table index
HS_CNT		EQU	2	; u8  counter of the current sub-step
HS_LFSR		EQU	3	; u8  3C509B ID sequence value
HS_DL		EQU	4	; u32 deadline of the current wait
HS_IO		EQU	8	; u16 0xC000 + io_base
HS_MAC		EQU	10	; u8[6] station address
HS_RXS		EQU	16	; u8  RX pipeline state (ERX_*)
HS_RXLEN	EQU	17	; u16 frame length reported by the card
HS_RXSKIP	EQU	19	; u16 card bytes summed but not stored (header tail)
HS_RXLIM	EQU	21	; u16 card bytes summed and stored
HS_RXREM	EQU	23	; u16 card bytes of the segment still to read
HS_RXDST	EQU	25	; u16 store pointer
HS_RXSPAN	EQU	27	; u16 bytes before the RX ring wraps
HS_SUM		EQU	29	; u16 checksum accumulator (byte-swapped)
HS_TXS		EQU	31	; u8  TX pipeline state (ETX_*)
HS_TXLEN	EQU	32	; u16 frame length without padding
HS_TXHDR	EQU	34	; u8  header bytes in ctx.txh
HS_TXREM	EQU	35	; u16 payload bytes still to write
HS_TXSRC	EQU	37	; u16 payload source
HS_TXKIND	EQU	39	; u8  ETK_*: who asked for the frame
HS_WIN		EQU	40	; u8  3C509B: selected register window
HS_RXSEG	EQU	41	; u16 transport segment length
HS_TMP		EQU	43	; u16 card scratch
HS_RES		EQU	45	; u8  result of the last portion
HS_NOCHK	EQU	46	; u8  1: segment without checksum (UDP checksum 0)
HS_PAR		EQU	47	; u8  1: the next segment byte has an odd offset
HS_BDL		EQU	48	; u32 deadline of the whole bring-up
HS_TXHSRC	EQU	52	; u16 header source of the frame being sent
HS_RXPROTO	EQU	54	; u8  IPv4 protocol of the frame being received
HS_NEXTPG	EQU	55	; u8  RTL8019AS: next-page field of the frame being read
HS_SIZE		EQU	56
	ASSERT	HS_SIZE <= 56

ERX_IDLE	EQU	0
ERX_HDR		EQU	1	; header in scratch, not classified
ERX_COPY	EQU	2
ERX_FINISH	EQU	3
ERX_DISCARD	EQU	4
ERX_DISC_WAIT	EQU	5
ERX_HDR_READ	EQU	6	; frame waiting, header not read yet
ERX_ACCEPT	EQU	7	; IPv4 checks passed, transport not asked yet
ERX_STORE	EQU	8	; transport accepted, payload placement not set up
ERX_SUM0	EQU	9	; IPv4 checks passed, segment checksum not started

ETX_IDLE	EQU	0
ETX_BEGIN	EQU	1	; header ready in ctx.txh
ETX_DATA	EQU	2
ETX_END		EQU	3
ETX_WAIT	EQU	4

ETK_ARP		EQU	1
ETK_TP		EQU	2

; Header template sums kept at the end of ctx.tp (both transports).
TPT_IPS0	EQU	92	; u16 IPv4 header sum with length 0 and checksum 0
TPT_L4S0	EQU	94	; u16 pseudo addresses + protocol + both ports


; ARP cache in ctx.arp (IX-relative)
AR_STATE	EQU	0	; u8  ARS_*
AR_IP		EQU	1	; ip4 next hop being resolved / cached
AR_MAC		EQU	5	; mac6
AR_DL		EQU	11	; u32 retry / refresh time
AR_TTL		EQU	15	; u32 entry expiry
AR_TRY		EQU	19	; u8  retry index
AR_FLAGS	EQU	20	; u8  ARF_*
AR_RQ_IP	EQU	21	; ip4 requester to answer
AR_RQ_MAC	EQU	25	; mac6
AR_SIZE		EQU	31
ARS_EMPTY	EQU	0
ARS_RESOLVING	EQU	1
ARS_VALID	EQU	2
ARF_REPLY	EQU	0x01	; an ARP reply is waiting to be sent
ARF_REQUEST	EQU	0x02	; an ARP request is waiting to be sent
ARF_FAILED	EQU	0x04	; resolution exhausted its schedule
ARP_MIN_RETRY_MS EQU	1000

	ENDIF
