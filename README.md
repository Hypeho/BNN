# BNN Wide-BDOT128 Validation

## 개요

- RV32I 기반 BNN inference용 Blocking Wide-BDOT128 architecture와 model별 validation 환경을 정리한 repository임.
- FINN LFC, FINN CNV, eBNN의 Multiple-Input RTL Correctness를 Vivado 2019.1 XSim에서 검증함.
- Prediction뿐 아니라 class score와 model별 intermediate result를 Software Golden과 exact match 방식으로 비교함.
- 세 model validation에서 공통 Wide-BDOT128 RTL architecture를 수정하지 않음.

상세 연구 흐름과 결과 해석은 [Wide-BDOT128 BNN Validation Summary](docs/wide_bdot128_validation_summary.md)를 참고함.

## Wide-BDOT128

- 128-bit Wide Activation/Weight BRAM을 직접 읽어 XNOR–Popcount를 수행함.
- BCFG가 Binary Dot Product length를 설정하고 BDOT가 내부에서 여러 128-bit block을 순회함.
- Blocking `ISSUE → WAIT → ACCUM` 방식으로 multi-block accumulation과 tail mask를 처리함.
- CPU가 반복 수행하던 Binary Dot Product loop를 accelerator 내부로 이동함.

## Multiple-Input XSim 2019.1 결과

| Model | Input | Samples | Prediction | Score | Intermediate | Overall |
|---|---|---:|---:|---:|---|:---:|
| FINN LFC | Binary-MNIST data | 20 | 20/20 | 20/20 | L0/L1/L2 activation 20/20 | PASS |
| FINN CNV | 실제 CIFAR-10 test input | 10 | 10/10 | 10/10 | Checksum 10개 10/10 | PASS |
| eBNN | Binary-MNIST data | 20 | 20/20 | 20/20 bit-exact | Checksum + packed activation 20/20 | PASS |

- Ground-truth label은 metadata로만 사용함.
- RTL expected output은 각 model의 Software/Host Golden 계산 결과를 사용함.
- Multiple-Input 결과는 XSim RTL Correctness이며 FPGA Multiple-Input 실행 결과가 아님.

## Model Documentation

- [FINN LFC README](models/finn_lfc/README.md)
- [FINN LFC Result](models/finn_lfc/results/finn_lfc_multiinput_results.md)
- [FINN CNV README](models/finn_cnv/README.md)
- [FINN CNV Result](models/finn_cnv/results/finn_cnv_multiinput_results.md)
- [eBNN README](models/ebnn/README.md)
- [eBNN Result](models/ebnn/results/ebnn_multiinput_results.md)

## Repository 구조

```text
BNN/
├── hardware/wide_bdot128/    # 공통 Wide-BDOT128 RTL 및 hardware 자료
├── models/
│   ├── finn_lfc/             # LFC software, Golden, testbench, runner, result
│   ├── finn_cnv/             # CNV software, Golden, testbench, runner, result
│   └── ebnn/                 # eBNN software, Golden, testbench, runner, result
├── docs/                     # 통합 문서, source inventory, toolchain
├── scripts/
└── results/
```

## 재현

- 공식 RTL Simulator는 `C:\Xilinx\Vivado\2019.1\bin`의 xvlog, xelab, xsim을 사용함.
- 상세 dependency, memory gate 및 resume 방식은 각 model README를 따름.
- repository root의 PowerShell에서 다음 runner를 사용함.

```powershell
& '.\models\finn_lfc\scripts\run_rv32i_lfc_multiinput_xsim.ps1' -Through Full
& '.\models\finn_cnv\scripts\run_finn_cnv_multiinput_xsim.ps1' -Through Full
& '.\models\ebnn\scripts\run_ebnn_multiinput_xsim.ps1' -Mode Full
```

## 현재 한계

- 검증 sample은 LFC 20개, CNV 10개, eBNN 20개이며 전체 dataset exhaustive validation이 아님.
- FPGA Multiple-Input execution은 수행하지 않음.
- 기존 Single-Input FPGA performance와 Multiple-Input XSim correctness는 별도 결과임.
- Pipeline 80 MHz 결과는 WNS -0.857 ns로 Timing-clean 결과가 아님.
- SAIF 기반 Power/Energy는 annotation coverage 약 8%의 preliminary 결과임.
- 다음 평가는 Timing-clean Pipeline 비교와 SAIF coverage를 보완한 Power/Energy 비교임.

## Repository 정책

- RTL, Validation Firmware, Testbench, Golden Generator, runner, 결과 CSV/Markdown 및 문서를 포함 후보로 관리함.
- XSim/Vivado cache, `work`, virtual environment, temporary build output 및 불필요한 대용량 log는 `.gitignore`로 제외함.
- 기존 source의 copyright, license 및 author header를 유지함.
- 현재 단계에서는 Git commit 또는 push를 수행하지 않음.
