# eBNN Binary-MNIST Wide-BDOT128 Validation

## 목적

- eBNN Binary-MNIST를 Wide-BDOT128에서 실행하고 Host Golden과 RTL 결과를 bit-exact하게 비교함.
- Single-Input 수준의 검증을 기존 Binary-MNIST input 20개에 대한 Multiple-Input Validation으로 확장함.
- 새로운 accelerator architecture를 추가하지 않고 기존 Wide-BDOT128의 Functional Correctness를 검증함.

## eBNN 구조

- 입력은 28×28 Binary-MNIST image이며 sample당 784 bits, 98 bytes임.
- Binary Convolution에서 10개 filter를 적용하고 pooling 결과를 10×6×6의 360-bit activation으로 생성함.
- Binary FC에서 360-bit activation과 10개 class weight를 비교하여 final score 10개를 계산함.
- final score의 maximum index를 model prediction으로 사용함.

## CPU와 Wide-BDOT128의 역할 분담

- Wide-BDOT128은 Binary Convolution과 Binary FC의 XNOR–Popcount를 수행함.
- Binary Convolution의 각 9-bit window는 BDOT 1회와 128-bit block 1개를 사용함.
- Binary FC의 각 360-bit vector는 BDOT 1회와 128-bit block 3개를 사용함.
- CPU는 input/window packing, pooling control, float Bias/BatchNorm, activation threshold, checksum 및 prediction 계산을 수행함.
- 전체 inference에서 BDOT은 3,250회, 128-bit block read는 3,270회 수행됨.

## Binary-MNIST Input

- [`baseline/common/binary_mnist_data.h`](baseline/common/binary_mnist_data.h)의 기존 sample 20개를 사용함.
- Ground-truth label은 validation metadata로만 사용함.
- source byte는 MSB-first pixel 순서로 해석하고 Wide-BRAM word는 bit index를 LSB 방향으로 packing함.
- 새로운 Dataset을 다운로드하거나 생성하지 않음.

## Golden 생성 방식

- [`scripts/generate_ebnn_multiinput_vectors.py`](scripts/generate_ebnn_multiinput_vectors.py)가 기존 eBNN parameter와 PC reference 연산을 독립 재현함.
- sample별 expected prediction, float class score bit pattern, 360-bit packed activation 및 Activation checksum을 생성함.
- 기존 PC reference prediction 20개와 Generated Golden prediction이 exact match함.
- 기존 sample 0의 prediction, score 10개 및 Activation checksum을 재현하여 Golden Gate를 통과함.

## Multiple-Input Validation 구조

- [`software/ebnn/main_ebnn_bdot_multi.c`](software/ebnn/main_ebnn_bdot_multi.c)가 compile-time sample ID로 input을 선택함.
- [`testbench/rv32i_ebnn_bdot_multi_tb.v`](testbench/rv32i_ebnn_bdot_multi_tb.v)가 Prediction, score, checksum 및 packed activation을 exact match 방식으로 비교함.
- [`scripts/check_ebnn_dmem_image.py`](scripts/check_ebnn_dmem_image.py)가 input, label, Bias/BN parameter와 Wide-BRAM weight image를 검사함.
- 각 raw log에 정확한 `result=PASS`가 있을 때만 완료된 case로 재사용함.

## XSim 2019.1 검증 방법

- 공식 RTL Simulator로 Vivado 2019.1 XSim의 xvlog, xelab, xsim을 사용함.
- RISC-V firmware는 RV32I/ILP32로 build하고 compressed instruction이 없음을 검사함.
- IMEM byte order, ELF의 loadable DMEM section 및 Wide-BRAM weight image를 simulation 전에 검사함.
- sample별 raw XSim log를 `logs/xsim2019_1/cases`에 저장함.

## 20-Input 결과

- 전체 20개 sample이 `RESULT PASS`함.
- Prediction exact match는 20/20임.
- Float class score bit-exact match는 20/20임.
- Activation checksum exact match는 20/20임.
- 360-bit packed activation exact match는 20/20임.
- 세부 결과는 [`results/ebnn_multiinput_results.md`](results/ebnn_multiinput_results.md)와 [`results/ebnn_multiinput_results.csv`](results/ebnn_multiinput_results.csv)에 기록함.

## Sample 19의 Label과 Prediction 차이

- Sample 19의 Ground-truth label은 9임.
- eBNN Host Golden expected prediction과 RTL actual prediction은 모두 7임.
- Prediction, score, checksum 및 packed activation은 모두 exact match함.
- Dataset label이 아니라 실제 eBNN Host Golden 계산 결과를 RTL expected output으로 사용했음을 보여줌.

## Cycle / BDOT / Block 결과

- Cycle minimum은 1,043,161임.
- Cycle maximum은 1,048,616임.
- Cycle average는 1,045,692.85임.
- Cycle range는 5,455임.
- BDOT count는 모든 input에서 3,250으로 동일함.
- Block count는 모든 input에서 3,270으로 동일함.
- Input별 Cycle variation의 정확한 원인은 본 단계에서 별도 분석하지 않음.

## 재현 방법

PowerShell에서 다음 명령을 사용함.

```powershell
Set-Location -LiteralPath 'C:\Project_V2\BNN'

& '.\models\ebnn\scripts\run_ebnn_multiinput_xsim.ps1' -Mode Single
& '.\models\ebnn\scripts\run_ebnn_multiinput_xsim.ps1' -Mode Full
```

- PASS raw log가 존재하는 case는 자동으로 재사용함.
- 진행 상태는 `show_ebnn_xsim_progress.ps1`로 확인함.
- 결과 Markdown만 다시 생성하려면 다음 명령을 사용함.

```powershell
python '.\models\ebnn\scripts\write_ebnn_results_markdown.py' full `
    --csv '.\models\ebnn\results\ebnn_multiinput_results.csv' `
    --output '.\models\ebnn\results\ebnn_multiinput_results.md'
```

## Known Limitations

- 본 결과는 Vivado 2019.1 XSim RTL Validation 범위임.
- FPGA Multiple-Input execution은 수행하지 않음.
- Power/Energy 평가는 본 단계의 범위가 아님.
- 20개 Binary-MNIST sample에 대한 검증이며 전체 Dataset에 대한 exhaustive validation은 아님.
- Input별 Cycle variation의 정확한 원인은 별도 분석하지 않음.
