# FINN LFC Wide-BDOT128 Validation

## 목적

- FINN LFC를 Wide-BDOT128 RV32I RTL에서 Multiple-Input 방식으로 검증함.
- Prediction뿐 아니라 class score와 Layer 0/1/2 packed activation을 bit-exact 방식으로 비교함.
- 최종 공식 RTL Simulator로 Vivado 2019.1 XSim을 사용함.

## FINN LFC 구조

- Binary-MNIST 784-bit input을 사용함.
- Hidden Layer 3개는 각각 1,024개의 binary neuron으로 구성됨.
- Output Layer는 10개 class score를 생성함.
- Weight, threshold, polarity는 `baseline/generated/lfc_params.h`에서 가져옴.

## Wide-BDOT128 적용 방식

- RV32I CPU에서 BCFG와 BDOT Custom Instruction을 실행함.
- BDOT width는 128 bits이며 blocking ISSUE → WAIT → ACCUM 구조를 사용함.
- Layer 0/1/2 activation과 output score 계산에 동일한 Wide-BDOT128 datapath를 사용함.
- 본 validation에서는 기존 RTL architecture를 수정하지 않음.

## Input

- `models/ebnn/baseline/common/binary_mnist_data.h`의 Binary-MNIST input 20개를 사용함.
- eBNN의 prediction, score, checksum은 FINN LFC Golden으로 사용하지 않음.
- Source byte의 pixel은 MSB-first로 읽고 FINN LFC `uint32` word의 LSB-first bit index로 packing함.
- Sample당 98 bytes, 784 bits, 25 words를 사용하며 마지막 word의 valid bit는 16 bits임.
- Sample 0 packed input이 기존 FINN LFC input 및 `activation0.hex`와 exact match함.

## Golden 생성 방식

- `software/lfc/generate_lfc_multiinput_vectors.py`가 외부 ONNX, PyTorch dependency 없이 Golden을 계산함.
- FINN LFC weight, threshold, polarity를 직접 해석해 ACT0, Layer 0/1/2 activation, score 10개, prediction을 생성함.
- Sample 0에서 prediction 5와 기존 score `[-182, -94, -34, 326, -162, 556, 54, 6, 216, -96]`을 재현함.
- Sample 0의 Layer 0/1/2 packed activation도 기존 reference image와 exact match함.
- 생성 vector는 `vectors/generated/multiinput/case_XX`에 저장함.

## XSim 2019.1 Validation 방법

- `scripts/run_rv32i_lfc_multiinput_xsim.ps1`이 firmware build부터 결과 요약까지 수행함.
- GNU objcopy output에 `--reverse-bytes=4`를 적용한 뒤 ELF 첫 instruction과 IMEM 첫 word를 비교함.
- DMEM byte-address marker를 32-bit word index로 변환함.
- `lfc_threshold0`와 `lfc_polarity0` symbol address의 실제 DMEM word를 header 값과 비교함.
- 긴 absolute plusarg 경로 문제를 피하기 위해 짧은 `work/xsim2019_1/mem` 경로에 image를 staging함.
- XSim 2019.1 호환성을 위해 quoted plusarg를 `.options` 파일로 전달함.
- Gate 1 sample 0, Gate 2 sample 0~2, Full sample 0~19 순으로 실행함.

## Multiple-Input 결과

- 전체 20개 sample이 XSim 2019.1에서 PASS함.
- Prediction exact match는 20/20임.
- Class score exact match는 20/20임.
- Layer 0, Layer 1, Layer 2 packed activation exact match는 각각 20/20임.
- Status는 전체 sample에서 1임.
- 상세 결과는 `results/finn_lfc_multiinput_results.csv`와 `results/finn_lfc_multiinput_results.md`에 기록함.

## Cycle / BDOT / Block 분석

- Cycle minimum은 121,399이며 maximum은 121,531임.
- Cycle average는 121,475.1이며 range는 132 cycles임.
- BDOT instruction count는 모든 sample에서 3,082임.
- 128-bit block count는 모든 sample에서 23,632임.
- O2 firmware disassembly에서 activation bit가 set되는 경로는 `if (ge == polarity)` 이후 두 instruction이 추가됨.
- Class maximum이 갱신되는 경로는 `if (score > best)` 이후 두 `mv` instruction이 추가됨.
- 20개 결과 모두 `cycles = 118431 + 2 × (Layer 0/1/2 activation set-bit 수) + 2 × (class maximum 갱신 횟수)`를 만족함.
- 따라서 cycle variation은 Wide-BDOT128 workload 변화가 아니라 input-dependent CPU-side branch 경로 차이로 확인됨.

## 재현 방법

Repository root에서 다음 명령을 실행함.

```powershell
powershell -ExecutionPolicy Bypass -File .\models\finn_lfc\scripts\run_rv32i_lfc_multiinput_xsim.ps1 -Through Full
```

- Python, RISC-V toolchain, Vivado 2019.1 executable은 runner 내부 absolute path를 사용함.
- PATH를 영구 변경하지 않음.
- Raw XSim log는 `logs/xsim2019_1`에 저장함.
- Vivado cache와 firmware build artifact는 `work`에 저장하며 공식 결과 directory와 분리함.

## Known Limitations

- 본 결과는 RTL Simulation 범위이며 FPGA Multiple-Input execution을 포함하지 않음.
- Input 20개는 repository에 포함된 제한된 Binary-MNIST subset임.
- FINN CNV와 eBNN의 완료 결과는 repository 최상위 통합 summary에서 별도로 정리함.
