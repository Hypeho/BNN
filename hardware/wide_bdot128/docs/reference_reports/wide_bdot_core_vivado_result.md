# Wide-BDOT128 BMG 포함 Vivado Core 구현 결과

> 상태: 아래 수치는 이전 accelerator 105 MHz 구조의 결과다. 현재 CPU/BDOT 35 MHz
> 통합형 OOC 및 board 결과는 `cpu_integrated_bdot35_implementation_result.md`를
> 따른다.

- 검증일: 2026-08-17
- Tool: Vivado 2024.2 / XSim
- Part: `xczu3eg-sbva484-1-e` (Ultra96 V1)
- 범위: RV32I CPU, CDC, BDOT128, Activation BMG 2개, Weight 400 KiB BMG
- 상태: behavioral simulation, OOC synthesis, place-and-route PASS

## 1. 확정 설계

- Weight BRAM: 400 KiB, `102400×32 / 25600×128`
- Activation BRAM: 각각 32 KiB, `8192×32 / 2048×128`
- Activation Port A: CPU/loader 32-bit R/W, 35 MHz
- Activation Port B: accelerator 128-bit read, 105 MHz
- Weight Port A: loader 32-bit R/W, 35 MHz
- Weight Port B: accelerator 128-bit read, 105 MHz
- BMG mode: True Dual Port, READ_FIRST, byte-write enable, read latency 1
- CPU와 accelerator reset: asynchronous assertion, 2-stage synchronous deassertion
- Activation 주소 검사는 두 뱅크를 독립 범위로 판정하며, 뱅크 사이의
  `0x30008000`~`0x3000ffff` 공백을 유효 주소로 허용하지 않음

`load_mode=1`일 때 CPU와 accelerator를 reset 상태로 유지하고 loader가 Port A를
소유한다. Loader interface는 CPU clock에 동기화돼야 한다. Board-level PS/AXI
연결에서는 AXI clock conversion 또는 35 MHz AXI BRAM controller가 필요하다.

## 2. 실제 BMG equivalence simulation

Vivado BMG behavioral model을 직접 instantiate해 다음을 검사했다.

1. 네 개의 32-bit Port-A write가 한 개의 128-bit Port-B word로 조립되는 순서
2. byte write enable로 한 byte만 변경되는 동작
3. Weight의 W3 local offset `0x5C000`에서 동일한 lane ordering
4. 서로 다른 35/105 MHz clock과 1-cycle synchronous read

```text
TB PASS: wide_bram_bmg_equivalence checks=3 errors=0
```

확정 lane ordering은 다음과 같다.

```text
doutb[31:0]    = lowest-address 32-bit word
doutb[63:32]   = next word
doutb[95:64]   = next word
doutb[127:96]  = highest-address word in the row
```

BMG behavioral model 자체는 동일 clock edge의 read/write collision을 실제 primitive와
완전히 같게 모델링하지 않는다. 현재 protocol은 load mode와 run mode를 분리하므로
그 collision 동작에 의존하지 않는다.

재현 명령:

```bash
./scripts/run_wide_bram_bmg_sim.sh
```

## 3. Post-route 자원

| 자원 | 사용 | Ultra96 가용 | 사용률 |
|---|---:|---:|---:|
| CLB LUT | 3,636 | 70,560 | 5.15% |
| CLB Register | 1,676 | 141,120 | 1.19% |
| RAMB36 | 116 | 216 | 53.70% |
| DSP | 0 | 360 | 0% |

RAMB36 116개는 Weight 100개와 Activation 16개이다. 이 OOC core에는 외부로 둔
Instruction 128 KiB와 CPU Data 64 KiB가 포함되지 않는다. 이 둘을 각각 RAMB36
32개와 16개로 구현하면 전체 memory 예상치는 164/216(75.9%)이다. PS, AXI
interconnect와 clock/reset IP의 LUT/FF는 위 표에 포함되지 않는다.

## 4. Post-route timing

| Clock/domain | Target | WNS | TNS | 결과 |
|---|---:|---:|---:|---|
| Accelerator | 104.998 MHz, 9.524 ns | +1.499 ns | 0 | MET |
| CPU | 35.001 MHz, 28.571 ns | +17.087 ns | 0 | MET |
| CPU→Accelerator bundle | max 9.524 ns | +8.651 ns | 0 | MET |
| Accelerator→CPU bundle | max 28.571 ns | +27.853 ns | 0 | MET |

모든 9,775개 routable net이 fully routed됐고 routing error는 0이다. Accelerator
critical path는 BRAM output에서 BDOT accumulator로 가는 XNOR/popcount/reduction
경로이며 post-route data path delay는 약 7.505 ns이다.

이 수치는 OOC core 결과다. 임시 `HD.CLK_SRC` 위치를 사용했으며 최종 Block
Design의 PS clock, clock wizard, AXI 및 실제 floorplan을 포함한 timing signoff가
별도로 필요하다.

재현 명령:

```bash
./scripts/run_wide_bdot_core_synth.sh
./scripts/run_wide_bdot_core_route.sh
```

## 5. CDC 결과와 해석

| CDC rule | 수 | 해석 |
|---|---:|---|
| CDC-3 Info | 2 | request/response toggle의 2-stage synchronizer 인식 |
| CDC-15 Warning | 129 | 96-bit request bundle + 33-bit response bundle |
| CDC-26 Warning | 2 | 두 domain reset synchronizer의 asynchronous assertion |

CDC-15는 의도한 bundled-data protocol이다. Source hold register는 toggle을 보낸 뒤
응답이 돌아올 때까지 유지되며, destination은 toggle 2-stage synchronization 후에
데이터를 capture한다. 단순 false-path로 숨기지 않고 CPU→accelerator 9.524 ns,
accelerator→CPU 28.571 ns의 `set_max_delay -datapath_only`를 적용했으며 post-route에서
모두 충족했다.

Reset은 비동기 assert, 각 domain 2-stage 동기 deassert 구조다. 최종 board reset
polarity와 PS reset sequence를 연결한 뒤 CDC report를 다시 검토한다.

## 6. Power report 주의사항

Vectorless post-route report는 다음 값을 냈다.

```text
Total on-chip = 0.257 W
Dynamic       = 0.035 W
Static        = 0.222 W
Block RAM dynamic = 0.026 W
Confidence    = Medium
```

실제 FINN LFC switching activity를 넣지 않았고 reset activity warning도 있으므로 이
수치를 energy/inference 결과로 사용하지 않는다. FPGA 실행 시 SAIF/VCD 또는 실측
전력을 사용해 다시 계산해야 한다.

## 7. 전체 회귀

400 KiB 전환과 address-range check 추가 후 다음을 다시 통과했다.

```text
wide_bram_wrapper          PASS, 7 checks
wide_xnor_popcount         PASS, 2,134 vectors
wide_bdot_accel            PASS, 18 tests
bdot_cpu_control           PASS
bdot_dual_clock            PASS
rv32i_bdot                 PASS
RV32I base compatibility   PASS, 136 cycles
XPC32 compatibility        PASS, 23 cycles
eBNN compatibility         PASS, 4,749,274 cycles, prediction 5
FINN LFC BDOT128           PASS, 105,699 cycles, prediction 5
actual BMG equivalence     PASS, 3 checks
```

18번째 accelerator test는 두 Activation 뱅크 사이 공백 주소를 의도적으로
요청해 즉시 error response가 발생하는지 확인한다. 이 수정 후에도 전체 LFC 결과는
105,699 cycle, prediction 5로 동일했고, 변경 RTL을 포함한 OOC route 결과도 위의
자원·timing 수치와 동일하게 통과했다.

## 8. Board-level 작업 상태

선택 1인 PS loader AXI 전체 35 MHz 구조로 Ultra96-V1 Block Design 통합을
완료했다. Instruction/Data BRAM과 loader AXI를 포함한 실제 결과는 RAMB36
164/216(75.93%), 전체 WNS +1.278 ns, DRC 0, routing error 0이며 bitstream과
XSA도 생성했다.

상세 결과는 `reports/ultra96v1_board_project_result.md`에 기록했다. 남은 작업은
XSA 기반 Vitis loader와 실제 보드에서 prediction, score, cycle, 전력을 검증하는
것이다.

### 8.1 기존 Block Design 조사와 clock 결정 필요 사항

기준 설계 `260726_XPC32_RegToReg/src/bd/design_1_35M.tcl`은 PS HPM AXI,
SmartConnect, AXI BRAM controller를 100 MHz로 동작시키고 CPU는 35 MHz로
분리한다. 현재 Wide-BDOT core의 Activation/Weight Port A는 load mode에서
PS loader가, run mode에서 CPU가 공유하므로 해당 port clock은 35 MHz로
고정돼 있다.

Board-level 연결 검토 당시의 선택지는 다음 두 안이었다.

1. **권장: PS HPM ACLK과 전체 loader AXI fabric을 35 MHz로 구동**
   - clock converter가 필요 없고 load/run 소유권 전환이 간단하다.
   - 초기 image load는 저하되지만 추론 중 성능에는 영향이 없다.
2. **기준 유지: PS AXI 100 MHz + 100→35 MHz clock conversion**
   - 초기 load는 빠르지만 SmartConnect 다중 clock 또는 AXI Clock Converter,
     reset-domain constraint가 추가된다.

최종적으로 추론 경로와 관계없는 일회성 image load 성능보다 clock/reset
단순성을 우선해 1안을 채택하고 구현했다.
