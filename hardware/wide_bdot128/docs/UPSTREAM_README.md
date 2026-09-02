# Wide-BRAM BDOT128

## 목적

FINN LFC-W1A1을 위한 128-bit blocking BDOT 가속기를 단계적으로 구현한다.
기존 `260726_XPC32_RegToReg`는 비교 기준으로 보존하며 이 작업본에서는 수정하지
않는다.

Standalone, RV32I blocking 통합 및 FINN LFC 전체 RTL 추론까지 완료했다.

- 32-bit Port A / 128-bit Port B memory lane mapping
- 128-bit masked XNOR-Popcount
- single/multi-block 누산
- 784-bit tail 처리
- request/busy/done/result protocol

## 기준

- FPGA: Avnet Ultra96 V1
- CPU clock: 35 MHz
- CPU/BDOT control and datapath clock: 35 MHz
- CPU-facing IMEM/DMEM and BDOT-facing wide BRAM read clock: 105 MHz
- Clock relationship: 1:3, same Clock Wizard, phase 0
- Accelerator width: 128 bit
- XPC32 reference: 776,741 cycles, 22.196 ms, prediction 5
- LFC BDOT count: 3,082
- LFC BDOT128 block count: 23,632

## 디렉터리

```text
analysis/   성능 및 break-even 계산
src/rtl/    standalone synthesizable RTL과 simulation memory model
testbench/  directed/random regression
```

## 기능시험

```bash
./testbench/run_all_functional_tests.sh
```

개별 시험도 각각 실행할 수 있다.

```bash
./testbench/run_wide_bram_wrapper.sh
./testbench/run_wide_xnor_popcount.sh
./testbench/run_wide_bdot_accel.sh
./testbench/run_bdot_cpu_control.sh
./testbench/run_rv32i_bdot_integration.sh
./testbench/run_rv32i_lfc_bdot.sh
./testbench/run_rv32i_cnv_bdot.sh
./testbench/run_rv32i_ebnn_bdot.sh
```

FINN CNV-W1A1은 첫 Q1.7 convolution을 CPU에 유지하고, 이후 binary
convolution/FC를 BDOT128로 실행한다. RTL full inference에서 prediction 3,
class score 및 10개 layer checksum이 golden과 일치했다. 자세한 결과는
`reports/cnv_bdot128_rtl_result.md`에 기록했다.

eBNN Binary-MNIST는 9-bit binary convolution과 360-bit FC에 BDOT128을
적용했다. 첫 MNIST sample의 prediction 5가 기존 RV32I 결과와 일치했고,
1,044,728 cycles로 통과했다. 자세한 결과는
`reports/ebnn_bdot128_rtl_result.md`에 기록했다.

`run_bdot_dual_clock_integration.sh`는 이전 35↔105 MHz accelerator CDC 구조를
재현하는 비교용 시험으로만 보존한다. 현재 CPU 통합형 기본 회귀에는 포함하지 않는다.

기존 CPU 호환성 회귀는 다음과 같다.

```bash
./testbench/run_legacy_compat_regressions.sh
```

`wide_bram_32xwide_model.v`은 비대칭 memory의 순수 RTL 기능검증 모델이다.
Vivado 단계에서는 동일한 interface contract를 만족하는 Block Memory Generator
wrapper로 교체하고 별도로 lane/latency equivalence를 검증한다.

## Break-even 계산

Standalone 시험에서 측정한 cycle을 사용해 다음처럼 계산한다.

```bash
python3 analysis/bdot_break_even.py \
  --host-cycles <CPU에_남는_cycle> \
  --start-cycles <BDOT당_start_cycle> \
  --block-ii <block당_cycle> \
  --finish-cycles <BDOT당_finish_cycle> \
  --cdc-cycles <전체_CDC_cycle>
```

FINN LFC RTL 결과는 `reports/lfc_bdot128_rtl_result.md`, memory image 계약은
`reports/lfc_memory_image_design.md`에 기록했다. FPGA BMG 등가검증·합성·전력
측정은 아직 남아 있다.

Vivado BMG 후보 생성과 OOC 자원 비교는 다음 명령과 문서에 있다.

```bash
./scripts/run_wide_bram_ip_build.sh
```

- `reports/wide_bram_bmg_ooc_result.md`

400 KiB BMG를 포함한 core simulation과 OOC 구현은 다음과 같다.

```bash
./scripts/run_wide_bram_bmg_sim.sh
./scripts/run_wide_bdot_core_synth.sh
./scripts/run_wide_bdot_core_route.sh
```

결과 해석은 `reports/wide_bdot_core_vivado_result.md`에 기록했다.
