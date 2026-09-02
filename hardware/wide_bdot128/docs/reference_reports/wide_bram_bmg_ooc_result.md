# Wide-BRAM BMG Out-of-Context 합성 결과

- 검증일: 2026-08-17
- Tool: Vivado 2024.2
- Part: `xczu3eg-sbva484-1-e` (Ultra96 V1)
- 상태: IP 생성 및 개별 OOC 합성 PASS, Weight 400 KiB 확정

## 1. 공통 BMG 설정

```text
Memory type       True Dual Port RAM
Port A            32-bit read/write, byte write enable
Port B            128-bit read/write interface, write enable은 wrapper에서 0 고정
Clock             independent (common clock=false)
Operating mode    READ_FIRST
Read latency      Port A=1, Port B=1
Output register   disabled
ECC/init file     disabled
```

Port A와 Port B의 byte 주소를 각각 word/row 주소로 변환하는 FPGA wrapper는
`src/rtl/wide_bram_bmg_wrapper.v`에 구현했다.

## 2. OOC 합성 결과

| BMG | 용량 | Port A depth | Port B depth | RAMB36E2 | CLB LUT |
|---|---:|---:|---:|---:|---:|
| Activation | 32 KiB | 8,192×32 | 2,048×128 | 8 | 84 |
| Weight 후보 A | 384 KiB | 98,304×32 | 24,576×128 | 96 | 1,168 |
| Weight 후보 B | 400 KiB | 102,400×32 | 25,600×128 | 100 | 1,254 |
| Weight 후보 C | 512 KiB | 131,072×32 | 32,768×128 | 128 | 1,504 |

Ultra96 V1 part에서 사용 가능한 Block RAM Tile은 RAMB36 기준 216개이다.
Activation BRAM 두 개는 16개를 사용한다.

## 3. 전체 memory budget 영향

계획한 Instruction 128 KiB와 CPU Data 64 KiB를 같은 32-bit BRAM 기준으로 각각
RAMB36 32개와 16개로 환산하면 다음과 같다. 이는 개별 BMG 산술 합계이며 아직
전체 place-and-route 결과는 아니다.

| Weight 용량 | 전체 예상 RAMB36 | 216개 대비 | 잔여 |
|---|---:|---:|---:|
| 384 KiB | 160 | 74.1% | 56 |
| 400 KiB | 164 | 75.9% | 52 |
| 512 KiB | 192 | 88.9% | 24 |

## 4. 용량별 의미

- 현재 BDOT128 aligned image는 378,112 B(369.25 KiB)이므로 세 후보 모두 수용한다.
- 384 KiB는 현재 image 뒤 여유가 15.25 KiB이지만, 계획서의 BDOT256 aligned
  예상치 385.25 KiB는 수용하지 못한다.
- 400 KiB는 BDOT256 예상치까지 수용하면서 512 KiB보다 RAMB36 28개와 LUT 약
  250개를 절약한다.
- 512 KiB는 가장 단순한 power-of-two decode와 126.75 KiB 확장 여유를 제공하지만
  전체 memory만으로 RAMB36 약 88.9%를 사용해 배치·배선 여유가 작다.

사용자 확인에 따라 **Weight BRAM은 400 KiB로 확정**했다. 유효 물리 범위는
`0x4000_0000~0x4006_3FFF`이며 software의 layer base/offset은 바뀌지 않는다.
실제 BMG module은 `weight_bram_400k_32x128`을 사용한다.

## 5. 재현

```bash
./scripts/run_wide_bram_ip_build.sh
```

Tcl은 Activation 및 세 Weight 후보를 모두 생성해 비교한다. Vivado project와 log는
재생성 산출물이므로 `.gitignore`에 포함했다.

## 6. 다음 검증

1. BMG simulation model로 32-bit write 후 128-bit lane/read-latency 등가시험을 한다.
2. CPU, CDC, BDOT, BMG를 포함한 전체 top을 합성·구현한다.
3. 35/105 MHz timing, CDC report 및 post-route 자원을 확인한다.
