# eBNN Binary-MNIST Wide-BDOT128 20-Input XSim 2019.1 Validation

## 검증 환경

- Vivado Simulator 2019.1의 xvlog, xelab, xsim을 사용함.
- `binary_mnist_data.h`의 기존 Binary-MNIST sample 20개를 사용함.
- Ground-truth label은 metadata로만 사용함.
- Expected prediction은 기존 eBNN parameter와 PC reference 동작을 독립 재현한 Host Golden을 사용함.
- 기존 Wide-BDOT128 RTL architecture를 수정하지 않음.

## Golden 검증

- 기존 PC reference prediction 20개와 Generated Golden prediction이 exact match함.
- 기존 Single-Input sample 0에서 Prediction, Float class score 10개, Activation checksum이 exact match함.
- Ground-truth label을 expected prediction으로 사용하지 않음.

## 결과

- 전체 sample 20개 모두 Overall PASS함.
- Prediction exact match는 20/20임.
- Float class score bit-exact match는 20/20임.
- Activation checksum exact match는 20/20임.
- 360-bit packed activation exact match는 20/20임.
- Cycle minimum은 1,043,161임.
- Cycle maximum은 1,048,616임.
- Cycle average는 1,045,692.85임.
- Cycle range는 5,455임.
- BDOT count는 모든 input에서 3,250으로 동일함.
- Block count는 모든 input에서 3,270으로 동일함.

| Sample | Label | Expected | Actual | Score | Checksum | Activation | Cycles | BDOT | Blocks | Result |
|---:|---:|---:|---:|:---:|:---:|:---:|---:|---:|---:|:---:|
| 0 | 5 | 5 | 5 | PASS | PASS | PASS | 1046677 | 3250 | 3270 | PASS |
| 1 | 0 | 0 | 0 | PASS | PASS | PASS | 1047733 | 3250 | 3270 | PASS |
| 2 | 4 | 4 | 4 | PASS | PASS | PASS | 1045017 | 3250 | 3270 | PASS |
| 3 | 1 | 1 | 1 | PASS | PASS | PASS | 1044243 | 3250 | 3270 | PASS |
| 4 | 9 | 9 | 9 | PASS | PASS | PASS | 1045404 | 3250 | 3270 | PASS |
| 5 | 2 | 2 | 2 | PASS | PASS | PASS | 1046225 | 3250 | 3270 | PASS |
| 6 | 1 | 1 | 1 | PASS | PASS | PASS | 1044609 | 3250 | 3270 | PASS |
| 7 | 3 | 3 | 3 | PASS | PASS | PASS | 1046350 | 3250 | 3270 | PASS |
| 8 | 1 | 1 | 1 | PASS | PASS | PASS | 1043161 | 3250 | 3270 | PASS |
| 9 | 4 | 4 | 4 | PASS | PASS | PASS | 1046701 | 3250 | 3270 | PASS |
| 10 | 3 | 3 | 3 | PASS | PASS | PASS | 1047122 | 3250 | 3270 | PASS |
| 11 | 5 | 5 | 5 | PASS | PASS | PASS | 1044451 | 3250 | 3270 | PASS |
| 12 | 3 | 3 | 3 | PASS | PASS | PASS | 1048616 | 3250 | 3270 | PASS |
| 13 | 6 | 6 | 6 | PASS | PASS | PASS | 1046632 | 3250 | 3270 | PASS |
| 14 | 1 | 1 | 1 | PASS | PASS | PASS | 1043269 | 3250 | 3270 | PASS |
| 15 | 7 | 7 | 7 | PASS | PASS | PASS | 1046535 | 3250 | 3270 | PASS |
| 16 | 2 | 2 | 2 | PASS | PASS | PASS | 1046721 | 3250 | 3270 | PASS |
| 17 | 8 | 8 | 8 | PASS | PASS | PASS | 1045976 | 3250 | 3270 | PASS |
| 18 | 6 | 6 | 6 | PASS | PASS | PASS | 1044500 | 3250 | 3270 | PASS |
| 19 | 9 | 7 | 7 | PASS | PASS | PASS | 1043915 | 3250 | 3270 | PASS |

### Sample 19 해석

- Ground-truth label은 9임.
- Host Golden expected prediction과 RTL actual prediction은 모두 7임.
- Prediction, Float class score, Activation checksum, packed activation이 모두 PASS함.
- Dataset label이 아니라 eBNN Host Golden 계산 결과를 RTL expected output으로 사용했음을 보여줌.

## Single-Input Gate

- Sample은 0이며 Ground-truth label은 5임.
- Expected / RTL prediction은 5 / 5임.
- Float class score bit-exact match는 PASS함.
- Activation checksum match는 PASS함.
- 360-bit packed activation match는 PASS함.
- Cycles는 1,046,677임.
- BDOT count는 3,250임.
- Block count는 3,270임.
- Status는 1이며 Address error는 0임.

## 범위

- 본 결과는 Vivado 2019.1 XSim RTL Validation 범위임.
- FPGA Multiple-Input execution은 수행하지 않음.
- Power/Energy 평가는 본 단계의 범위가 아님.
- 20개 Binary-MNIST sample에 대한 검증이며 전체 Dataset에 대한 exhaustive validation은 아님.
- Input별 Cycle variation의 정확한 원인은 이번 단계에서 별도 분석하지 않음.
