# Source Inventory

확인일은 2026-09-02임.

## Source 기준

- Downloads의 `RV32I-Project-main.zip`에서 최신 Wide-BDOT128 source를 확인함.
- GitHub `hosung-cho/RV32I-Project`의 현재 main tree와 ZIP 내부 관련 179개 파일의 Git blob hash를 비교함.
- 조사 대상 179개 파일이 모두 exact match함.
- `260817_Wide_BDOT128` 경로의 최신 확인 commit은 `5c0fedff8eaf`이며 FINN CNV, eBNN, Pipeline LFC, SAIF 관련 source가 포함됨.
- 기존 `C:\Project_V2\ULP_ML\BDOT128_MultiInput`에는 FINN LFC Multiple-Input 전용 generator, testbench, runner가 추가되어 있음.
- 기존 결과 CSV, Markdown, simulation log, waveform, Vivado workspace는 새 repository에 복사하지 않음.

## 공통 Wide-BDOT128 RTL

- 공통 RTL은 `hardware/wide_bdot128/rtl`에 배치함.
- `rv32i_cpu.v`, `wide_bdot_accel.v`, `wide_xnor_popcount.v`, `wide_bram_bmg_wrapper.v`, `wide_bram_32xwide_model.v` 등을 포함함.
- CPU/BDOT control과 wide BRAM clock domain 연결 source를 포함함.
- RTL architecture를 수정하지 않음.

## FINN LFC

### 최신 Wide-BDOT128 위치

- Upstream 위치는 `FPGA/BNN/260817_Wide_BDOT128/software/lfc`임.
- 새 workspace 위치는 `models/finn_lfc/software/lfc`임.
- 기존 Multiple-Input extension은 `generate_lfc_multiinput_vectors.py`, `rv32i_lfc_bdot_multi_tb.v`, `run_rv32i_lfc_multiinput.ps1`임.

### Input source

- 기존 single-input은 `lfc_params.h`의 packed 784-bit input을 사용함.
- Multiple-Input extension은 eBNN `binary_mnist_data.h`의 20개 Binary-MNIST input data만 사용함.
- eBNN prediction 또는 checksum을 FINN LFC Golden으로 사용하지 않음.

### Golden 생성 방식

- `generate_lfc_multiinput_vectors.py`가 FINN LFC weight, threshold, polarity를 직접 해석함.
- ACT0, Layer 0/1/2 packed activation, 10개 class score, prediction을 dependency-free 방식으로 계산함.
- 기존 정상 sample의 packed input, prediction 5, 기준 score 10개를 Golden Gate로 확인하도록 구현되어 있음.

### Testbench / 실행 상태

- 기존 single-input testbench는 `rv32i_lfc_bdot_tb.v`임.
- Multiple-Input testbench는 `rv32i_lfc_bdot_multi_tb.v`임.
- Multiple-Input testbench는 status, prediction, score, Layer 0/1/2 activation, BDOT count, block count를 검사함.
- 기존 PowerShell runner는 Windows RISC-V toolchain과 WSL Icarus 13.0을 사용함.
- XSim 2019.1 전용 Multiple-Input runner는 아직 없음.
- 새 directory layout에 맞춘 source path 수정과 XSim runner 작성 후 20-input 실행이 가능함.

## FINN CNV

### 최신 Wide-BDOT128 위치

- Upstream 위치는 `FPGA/BNN/260817_Wide_BDOT128/software/cnv`임.
- 새 workspace 위치는 `models/finn_cnv/software/cnv`임.
- Wide-BDOT128 firmware, image generator, testbench, runner, Vitis loader가 존재함.

### Input source

- 현재 `cnv_params.h`에 단일 CIFAR-10 input `cnv_input_q7_hwc`가 포함됨.
- 현재 공개 source에는 추가 input `.npz`, 원본 checkpoint `.pth`, ONNX file이 포함되지 않음.

### Golden 생성 방식

- `analysis/generate_cnv_params.py`가 PyTorch, Brevitas, checkpoint, preprocessed sample을 사용해 parameter와 reference를 생성하는 구조임.
- Wide image generator는 이미 생성된 `cnv_params.h`의 input, threshold, polarity, expected layer checksum을 재배치함.
- Wide image generator 자체가 새로운 input의 독립 Golden inference를 수행하지는 않음.

### Testbench / 실행 상태

- `rv32i_cnv_bdot_tb.v`는 single-input status, prediction, layer checksum, BDOT count, block count를 검사함.
- single-input Wide-BDOT128 runner와 Vitis loader가 존재함.
- 새로운 Multiple-Input 실행에는 additional CIFAR-10 input과 bit-exact Golden 생성 경로가 필요함.
- 현재 source만으로 FINN CNV Multiple-Input 실행을 바로 시작할 수 없음.

## eBNN

### 최신 Wide-BDOT128 위치

- Upstream 위치는 `FPGA/BNN/260817_Wide_BDOT128/software/ebnn`임.
- 새 workspace 위치는 `models/ebnn/software/ebnn`임.
- Wide-BDOT128 firmware, image generator, testbench, runner, Vitis loader가 존재함.

### Input source

- `binary_mnist_data.h`에 20개 Binary-MNIST input과 ground-truth label이 존재함.
- 현재 Wide-BDOT128 firmware는 첫 번째 input을 고정 사용함.

### Golden 생성 방식

- baseline PC source가 eBNN weight와 Binary-MNIST input으로 prediction, score bit pattern, checksum을 계산함.
- Wide image generator는 aligned weight 및 activation bank image를 생성함.
- 현재 Wide image generator에는 20개 input별 독립 Golden export 기능이 없음.

### Testbench / 실행 상태

- `rv32i_ebnn_bdot_tb.v`는 single-input status, prediction, checksum, score bit pattern, BDOT count, block count를 검사함.
- single-input Wide-BDOT128 runner와 Vitis loader가 존재함.
- 20개 input source는 확보되어 있으나 firmware input 선택, Golden export, testbench parameterization, runner 확장이 필요함.
- 현재 상태는 Multiple-Input 추가 작업이 가능한 source 기반은 있으나 바로 실행 가능한 상태는 아님.

## 복사 정책

- 공통 RTL과 model-specific source를 분리함.
- upstream source 파일 내용은 변경하지 않고 복사함.
- historical report는 `docs` 또는 `reference_reports` 아래에만 보관함.
- build output과 이전 실험 결과는 새 `results` 또는 `logs`에 복사하지 않음.

