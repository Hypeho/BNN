# FINN CNV Wide-BDOT128 Validation

## 목적

- FINN CNV-W1A1을 Wide-BDOT128 기반 RV32I RTL에서 실행하고 Software Golden과 bit-exact하게 비교함.
- 실제 CIFAR-10 test input 10개를 이용하여 Single-Input 수준의 검증을 Multiple-Input correctness validation으로 확장함.
- Prediction뿐 아니라 Class Score 10개와 Intermediate Checksum 10개를 함께 검증함.
- 본 작업에서는 기존 Wide-BDOT128 RTL architecture를 변경하지 않음.

## FINN CNV 구조

- 입력은 `32 x 32 x 3` CIFAR-10 image임.
- First Convolution은 Q1.7 signed input과 binary weight를 이용하여 CPU에서 계산함.
- 이후 Binary Convolution은 64, 128, 256 channel 단계로 구성됨.
- 두 개의 `2 x 2` Max Pooling stage를 포함함.
- 분류부는 Binary FC 2개와 10-class Final FC로 구성됨.
- 각 binary stage는 Threshold와 Polarity를 이용하여 activation bit를 결정함.
- Final FC score는 XNOR match 수에 대해 `2 * matches - 512`로 계산함.

연산 순서는 다음과 같음.

1. First Convolution: `30 x 30 x 64` activation을 생성함.
2. Binary Convolution 1: `28 x 28 x 64` activation을 생성함.
3. Max Pooling 1: `14 x 14 x 64` activation을 생성함.
4. Binary Convolution 2: `12 x 12 x 128` activation을 생성함.
5. Binary Convolution 3: `10 x 10 x 128` activation을 생성함.
6. Max Pooling 2: `5 x 5 x 128` activation을 생성함.
7. Binary Convolution 4: `3 x 3 x 256` activation을 생성함.
8. Binary Convolution 5: `1 x 1 x 256` activation을 생성함.
9. Binary FC 0: 512-bit activation을 생성함.
10. Binary FC 1: 512-bit activation을 생성함.
11. Final FC: Class Score 10개와 Prediction을 생성함.

## Wide-BDOT128 적용 방식

- First Convolution과 Max Pooling은 RV32I firmware에서 수행함.
- Binary Convolution, Binary FC 및 Final FC의 XNOR–Popcount를 Wide-BDOT128로 수행함.
- `BCFG`로 현재 binary vector 길이를 설정하고 `BDOT`으로 activation/weight block의 match 수를 계산함.
- Wide-BDOT128은 128-bit block 단위의 blocking 연산을 사용함.
- CPU와 accelerator 사이의 기존 `ISSUE → WAIT → ACCUM` 동작 및 RTL datapath를 변경하지 않음.
- Channel 수와 FC input 길이에 따라 하나의 BDOT instruction이 처리하는 유효 bit 수가 달라짐.

## CIFAR-10 Input 구성

- 공식 CIFAR-10 test split의 실제 image를 사용함.
- Ground-truth class 0~9를 각각 포함하도록 다음 10개 dataset index를 선택함.

| Sample | Dataset Index | Ground-truth Label | FINN Golden Prediction |
|---:|---:|---:|---:|
| 0 | 0 | 3 | 3 |
| 1 | 1 | 8 | 8 |
| 2 | 3 | 0 | 8 |
| 3 | 4 | 6 | 6 |
| 4 | 6 | 1 | 1 |
| 5 | 11 | 9 | 9 |
| 6 | 12 | 5 | 5 |
| 7 | 13 | 7 | 7 |
| 8 | 22 | 4 | 4 |
| 9 | 25 | 2 | 2 |

- Ground-truth label과 FINN Golden prediction을 별도 metadata로 관리함.
- Sample 2는 Ground-truth label이 0이지만 FINN Golden prediction과 RTL prediction이 모두 8임.
- 따라서 Dataset label을 RTL expected output으로 사용하지 않고 FINN CNV 계산 결과를 Golden으로 사용함.

## Input 전처리

- 원본 image 형식은 unsigned 8-bit `HWC (32, 32, 3)`임.
- 각 pixel을 `2 * pixel / 255 - 1`로 정규화함.
- 정규화 값을 `round(value * 128)`로 변환한 뒤 `[-128, 127]`로 clip하여 signed int8 Q1.7 값을 생성함.
- Firmware input은 HWC 순서의 3,072-byte contiguous array로 저장함.
- 기존 FINN single sample과 CIFAR-10 test index 0의 raw pixel이 exact match함을 확인함.
- 기존 header와 생성된 index 0 Q1.7 input이 byte 단위로 exact match함을 Golden Gate로 사용함.

## Golden 생성 방식

- `scripts/generate_finn_cnv_multiinput_vectors.py`를 사용함.
- PyTorch/Brevitas checkpoint 추론 대신 저장된 exported Weight, Threshold 및 Polarity parameter를 직접 사용함.
- First Convolution, Binary Convolution, Max Pooling, Binary FC 및 Final FC를 독립 Python reference로 계산함.
- 각 sample에 대해 다음 항목을 생성함.
  - Q1.7 input을 포함한 case별 firmware parameter header를 생성함.
  - Class Score 10개를 생성함.
  - FINN Golden prediction을 생성함.
  - Intermediate Checksum 10개를 생성함.
  - Dataset index와 Ground-truth label metadata를 생성함.
- 기존 정상 sample에 대해 Prediction 3, Class Score 10개 및 Intermediate Checksum 10개가 기존 reference와 exact match한 뒤 Multiple-Input vector를 사용함.

기존 정상 sample의 Class Score는 다음과 같음.

```text
[-40, -46, -32, 404, -30, 24, -14, -28, -16, -42]
```

## XSim 2019.1 Validation 방법

- Vivado 2019.1의 `xvlog`, `xelab`, `xsim`을 공식 RTL Simulator로 사용함.
- `scripts/run_finn_cnv_multiinput_xsim.ps1`에서 firmware build, memory image 생성, compile, elaborate, simulation, 결과 parsing 및 summary 생성을 자동화함.
- 각 sample을 독립 firmware/memory staging directory에서 실행함.
- 다음 memory image gate를 simulation 전에 수행함.
  - ELF 첫 instruction과 IMEM 첫 word를 비교하여 byte order를 확인함.
  - objcopy byte address marker를 RTL의 32-bit word index로 정규화함.
  - CPU-side input, weight, threshold, polarity 및 expected checksum 전체 byte를 DMEM image와 비교함.
- 기존 PASS raw log가 있으면 해당 case를 재실행하지 않고 결과를 재사용함.
- RTL 결과의 `status`, Prediction, Score 10개, Checksum 10개, cycles, BDOT count 및 block count를 case별 raw log에 저장함.

Windows PowerShell에서 다음과 같이 실행함.

```powershell
Set-Location -LiteralPath 'C:\Project_V2\BNN'

& '.\models\finn_cnv\scripts\run_finn_cnv_multiinput_xsim.ps1' `
    -Through Full
```

- 기존 vector를 재사용할 때는 `-RegenerateVectors`를 지정하지 않음.
- XSim 실행 중에는 PowerShell 창을 유지하고 PC 절전을 해제함.
- Vivado GUI는 필요하지 않음.
- 동일한 `work\xsim2019_1` directory를 사용하는 XSim을 동시에 실행하지 않음.

## 10-Input 결과

- 전체 10개 sample이 PASS함.
- Ground-truth class coverage는 0~9 전체임.
- Prediction exact match는 10/10임.
- Class Score 10개 exact match는 10/10임.
- Intermediate Checksum 10개 exact match는 10/10임.

| Sample | Dataset Index | Label | Expected | RTL | Score | Checksum | Cycles | BDOT | Blocks | Result |
|---:|---:|---:|---:|---:|:---:|:---:|---:|---:|---:|:---:|
| 0 | 0 | 3 | 3 | 3 | PASS | PASS | 29,498,135 | 756,746 | 761,128 | PASS |
| 1 | 1 | 8 | 8 | 8 | PASS | PASS | 29,476,447 | 756,746 | 761,128 | PASS |
| 2 | 3 | 0 | 8 | 8 | PASS | PASS | 29,468,057 | 756,746 | 761,128 | PASS |
| 3 | 4 | 6 | 6 | 6 | PASS | PASS | 29,478,011 | 756,746 | 761,128 | PASS |
| 4 | 6 | 1 | 1 | 1 | PASS | PASS | 29,528,328 | 756,746 | 761,128 | PASS |
| 5 | 11 | 9 | 9 | 9 | PASS | PASS | 29,510,024 | 756,746 | 761,128 | PASS |
| 6 | 12 | 5 | 5 | 5 | PASS | PASS | 29,491,487 | 756,746 | 761,128 | PASS |
| 7 | 13 | 7 | 7 | 7 | PASS | PASS | 29,525,291 | 756,746 | 761,128 | PASS |
| 8 | 22 | 4 | 4 | 4 | PASS | PASS | 29,470,475 | 756,746 | 761,128 | PASS |
| 9 | 25 | 2 | 2 | 2 | PASS | PASS | 29,472,670 | 756,746 | 761,128 | PASS |

- 상세 수치는 `results/finn_cnv_multiinput_results.csv`에 저장함.
- 사람이 읽을 수 있는 summary는 `results/finn_cnv_multiinput_results.md`에 저장함.
- case별 원본 XSim 출력은 `logs/xsim2019_1/cases`에 저장함.

## Prediction / Score / Checksum 검증

- Prediction은 FINN Golden prediction과 RTL prediction을 직접 비교함.
- Score는 10개 class의 signed integer 값을 모두 exact match 방식으로 비교함.
- Checksum은 다음 10개 intermediate stage의 packed activation 전체를 대상으로 계산함.
  1. First Convolution output
  2. Binary Convolution 1 output
  3. Max Pooling 1 output
  4. Binary Convolution 2 output
  5. Binary Convolution 3 output
  6. Max Pooling 2 output
  7. Binary Convolution 4 output
  8. Binary Convolution 5 output
  9. Binary FC 0 output
  10. Binary FC 1 output
- Prediction만 일치한 경우는 PASS로 처리하지 않음.
- `status = 1`, Prediction, Score 10개 및 Checksum 10개가 모두 일치한 경우에만 sample PASS로 처리함.

## Cycle / BDOT / Block 분석

- Cycle minimum은 29,468,057임.
- Cycle maximum은 29,528,328임.
- Cycle average는 29,491,892.5임.
- Cycle range는 60,271임.
- BDOT instruction count는 모든 input에서 756,746으로 동일함.
- 128-bit block count는 모든 input에서 761,128로 동일함.
- 동일한 network 구조와 binary workload가 실행되므로 BDOT 및 block workload가 input에 따라 변하지 않았음을 실제 결과로 확인함.
- Cycle은 sample에 따라 소폭 달랐으나 구체적인 원인은 본 validation 단계에서 확정하지 않음.
- CPU-side input-dependent control flow의 영향 가능성을 결과로 단정하지 않음.

## 기존 Single-Input Regression

- 수정하지 않은 기존 `testbench/rv32i_cnv_bdot_tb.v`를 XSim 2019.1에서 다시 실행함.
- Prediction은 3이며 expected 3과 일치함.
- Class Score는 `[-40, -46, -32, 404, -30, 24, -14, -28, -16, -42]`로 기존 기준과 exact match함.
- Intermediate Checksum 검증이 PASS함.
- Cycle은 29,498,135임.
- BDOT count는 756,746임.
- Block count는 761,128임.
- 최종 `TB PASS: FINN CNV BDOT128`을 확인함.

## 재현 방법

- Vivado 2019.1 XSim과 RV32I GNU toolchain을 준비함.
- Python validation 환경에는 NumPy, PyArrow 및 Pillow가 필요함.
- `vectors/generated/multiinput/case_00`부터 `case_09`까지의 vector와 metadata를 확인함.
- 위 PowerShell 명령으로 `-Through Full` regression을 실행함.
- runner가 출력하는 `FINAL PASS samples=10`을 확인함.
- 다음 결과를 확인함.

```powershell
Import-Csv '.\models\finn_cnv\results\finn_cnv_multiinput_results.csv' |
    Format-Table

Get-Content '.\models\finn_cnv\results\finn_cnv_multiinput_results.md'

Select-String `
    -Path '.\models\finn_cnv\logs\xsim2019_1\cases\*.log' `
    -Pattern '^RESULT '
```

- Windows PowerShell 5.x에서 기본 `Get-Content` encoding 처리로 한글이 깨져 보일 수 있으므로 Markdown 파일 손상으로 판단하지 않음.
- 필요하면 UTF-8 encoding을 명시하거나 PowerShell 7을 사용함.

## Known Limitations

- 본 Multiple-Input 결과는 Vivado 2019.1 XSim 기반 RTL validation 결과임.
- FPGA Multiple-Input execution은 수행하지 않음.
- Power 및 Energy 평가는 본 단계의 범위가 아님.
- 10개 input으로 class coverage를 확보했지만 CIFAR-10 전체 test split에 대한 검증은 수행하지 않음.
- Ground-truth classification accuracy 평가와 RTL correctness validation은 서로 다른 항목임.
- Cycle variation의 구체적인 firmware control-flow 원인은 본 단계에서 확정하지 않음.
