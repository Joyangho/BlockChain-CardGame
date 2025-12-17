CardGameVRF (Chainlink VRF + 예치금 + 서명 기반 가스리스 게임) PoC
개요

사용자는 SABU 토큰을 컨트랙트에 예치하고, 게임은 EIP-712 서명만으로 진행합니다.

실제 트랜잭션은 릴레이어(relayer) 가 제출하고, 난수는 Chainlink VRF v2.5(구독 방식) 로 생성됩니다.

무승부는 참가비가 즉시 환급되며, 승리 보상은 적립 후 출금합니다(출금 시 5% 수수료).

게임 흐름

Deposit: deposit(amount)

Play(가스리스): 지갑에서 서명 → relayer가 startGameWithSig(intent, sig) 호출

VRF 결과 확정: GameResolved 이벤트 확인

Withdraw

예치금: withdrawDeposit(amount)

당첨금: withdrawWinnings() (5% 수수료 공제)

룰

참가비: entryFee

승리 보상: reward

무승부: 참가비 환급(예치금으로 복구)

패배: 참가비는 하우스 수익(컨트랙트에 잔류)

운영자(하우스) 설정

Chainlink VRF Subscription 생성/충전 후 컨트랙트를 consumer로 등록

relayer 주소를 설정하고 relayer가 트랜잭션을 제출

하우스 출금은 withdrawHouse()로 가능하며, 예치금/당첨금/대기 예약금은 잠금 처리되어 보호됩니다.

보안 메모

deposit()은 실제 입금량(received) 기준으로 적립하여 전송세 토큰에도 안전하게 동작하도록 설계했습니다.

서명 제출자는 relayer로 제한되어, 임의 제3자의 서명 제출을 방지합니다.

VRF 지연 시 refundAfterTimeout()으로 참가비 환급이 가능합니다.
