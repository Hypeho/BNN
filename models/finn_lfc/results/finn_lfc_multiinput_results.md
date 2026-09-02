# FINN LFC Wide-BDOT128 20-Input XSim 2019.1 Validation

## 검증 환경

- Vivado Simulator 2019.1의 xvlog, xelab, xsim을 사용함.
- Binary-MNIST input data만 사용하고 FINN LFC parameter로 Golden을 독립 생성함.
- 기존 Wide-BDOT128 RTL architecture를 수정하지 않음.

## Golden Gate

- Sample 0 packed input이 기존 FINN LFC input과 exact match함.
- Prediction 5와 기준 class score 10개가 exact match함.
- Layer 0, Layer 1, Layer 2 packed activation이 기존 reference와 exact match함.

## 결과

- 전체 sample은 20개이며 Overall 결과는 PASS임.
- Prediction exact match는 20/20임.
- Class score exact match는 20/20임.
- Layer 0/1/2 exact match는 20/20, 20/20, 20/20임.
- Cycle은 minimum 121399, maximum 121531, average 121475.1, range 132임.
- BDOT count unique value는 3082임.
- Block count unique value는 23632임.

| Sample | Label | Expected | Actual | Score | L0 | L1 | L2 | Cycles | BDOT | Blocks | Result |
|---:|---:|---:|---:|:---:|:---:|:---:|:---:|---:|---:|---:|:---:|
| 0 | 5 | 5 | 5 | PASS | PASS | PASS | PASS | 121521 | 3082 | 23632 | PASS |
| 1 | 0 | 0 | 0 | PASS | PASS | PASS | PASS | 121435 | 3082 | 23632 | PASS |
| 2 | 4 | 4 | 4 | PASS | PASS | PASS | PASS | 121509 | 3082 | 23632 | PASS |
| 3 | 1 | 1 | 1 | PASS | PASS | PASS | PASS | 121487 | 3082 | 23632 | PASS |
| 4 | 9 | 9 | 9 | PASS | PASS | PASS | PASS | 121399 | 3082 | 23632 | PASS |
| 5 | 2 | 2 | 2 | PASS | PASS | PASS | PASS | 121481 | 3082 | 23632 | PASS |
| 6 | 1 | 1 | 1 | PASS | PASS | PASS | PASS | 121407 | 3082 | 23632 | PASS |
| 7 | 3 | 3 | 3 | PASS | PASS | PASS | PASS | 121475 | 3082 | 23632 | PASS |
| 8 | 1 | 1 | 1 | PASS | PASS | PASS | PASS | 121469 | 3082 | 23632 | PASS |
| 9 | 4 | 4 | 4 | PASS | PASS | PASS | PASS | 121463 | 3082 | 23632 | PASS |
| 10 | 3 | 3 | 3 | PASS | PASS | PASS | PASS | 121461 | 3082 | 23632 | PASS |
| 11 | 5 | 5 | 5 | PASS | PASS | PASS | PASS | 121527 | 3082 | 23632 | PASS |
| 12 | 3 | 3 | 3 | PASS | PASS | PASS | PASS | 121449 | 3082 | 23632 | PASS |
| 13 | 6 | 6 | 6 | PASS | PASS | PASS | PASS | 121467 | 3082 | 23632 | PASS |
| 14 | 1 | 1 | 1 | PASS | PASS | PASS | PASS | 121465 | 3082 | 23632 | PASS |
| 15 | 7 | 7 | 7 | PASS | PASS | PASS | PASS | 121519 | 3082 | 23632 | PASS |
| 16 | 2 | 2 | 2 | PASS | PASS | PASS | PASS | 121531 | 3082 | 23632 | PASS |
| 17 | 8 | 8 | 8 | PASS | PASS | PASS | PASS | 121517 | 3082 | 23632 | PASS |
| 18 | 6 | 6 | 6 | PASS | PASS | PASS | PASS | 121407 | 3082 | 23632 | PASS |
| 19 | 9 | 9 | 9 | PASS | PASS | PASS | PASS | 121513 | 3082 | 23632 | PASS |

## Cycle / Workload 해석

- BDOT instruction count 3,082와 128-bit block count 23,632는 모든 sample에서 동일함.
- O2 firmware disassembly에서 activation bit가 set되는 조건 분기는 두 instruction을 추가 실행함.
- Class score가 기존 maximum을 갱신하는 조건 분기도 두 instruction을 추가 실행함.
- 20개 sample 모두 `cycles = 118431 + 2 × (Layer 0/1/2 activation set-bit 수) + 2 × (class maximum 갱신 횟수)`를 만족함.
- Cycle 차이는 Wide-BDOT128 workload 차이가 아니라 input-dependent CPU-side branch 경로 차이로 확인됨.

## 기존 Single-Input Regression

- Prediction은 5이며 결과는 PASS임.
- Scores는 [-182,-94,-34,326,-162,556,54,6,216,-96]이며 기존 기준과 exact match함.
- Cycles는 121521, BDOT은 3082, Blocks는 23632임.

## 범위

- 본 결과는 RTL XSim validation 범위임.
- FPGA Multiple-Input execution은 수행하지 않음.
