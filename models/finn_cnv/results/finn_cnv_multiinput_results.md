# FINN CNV Wide-BDOT128 10-Input XSim 2019.1 Validation

## 검증 환경

- Vivado Simulator 2019.1의 xvlog, xelab, xsim을 사용함.
- 공식 CIFAR-10 test split의 실제 input을 사용함.
- Exported Weight/Threshold/Polarity 기반 독립 Golden을 생성함.
- 기존 Wide-BDOT128 RTL architecture를 수정하지 않음.

## Golden Gate

- 공식 FINN class-3 sample과 CIFAR-10 test index 0의 raw pixel이 exact match함.
- HWC int8 Q1.7 packed input이 기존 header와 exact match함.
- Prediction, class score 10개, intermediate checksum 10개가 기존 reference와 exact match함.

## 결과

- 전체 sample은 10개이며 Overall 결과는 PASS임.
- Ground-truth class coverage는 0, 1, 2, 3, 4, 5, 6, 7, 8, 9임.
- Prediction exact match는 10/10임.
- Class score exact match는 10/10임.
- Intermediate checksum 10개 전체 exact match는 10/10임.
- Cycle은 minimum 29468057, maximum 29528328, average 29491892.5, range 60271임.
- BDOT count unique value는 756746임.
- Block count unique value는 761128임.

| Sample | Dataset Index | Label | Expected | Actual | Score | Checksum | Cycles | BDOT | Blocks | Result |
|---:|---:|---:|---:|---:|:---:|:---:|---:|---:|---:|:---:|
| 0 | 0 | 3 | 3 | 3 | PASS | PASS | 29498135 | 756746 | 761128 | PASS |
| 1 | 1 | 8 | 8 | 8 | PASS | PASS | 29476447 | 756746 | 761128 | PASS |
| 2 | 3 | 0 | 8 | 8 | PASS | PASS | 29468057 | 756746 | 761128 | PASS |
| 3 | 4 | 6 | 6 | 6 | PASS | PASS | 29478011 | 756746 | 761128 | PASS |
| 4 | 6 | 1 | 1 | 1 | PASS | PASS | 29528328 | 756746 | 761128 | PASS |
| 5 | 11 | 9 | 9 | 9 | PASS | PASS | 29510024 | 756746 | 761128 | PASS |
| 6 | 12 | 5 | 5 | 5 | PASS | PASS | 29491487 | 756746 | 761128 | PASS |
| 7 | 13 | 7 | 7 | 7 | PASS | PASS | 29525291 | 756746 | 761128 | PASS |
| 8 | 22 | 4 | 4 | 4 | PASS | PASS | 29470475 | 756746 | 761128 | PASS |
| 9 | 25 | 2 | 2 | 2 | PASS | PASS | 29472670 | 756746 | 761128 | PASS |

## 기존 Single-Input Regression

- Prediction은 3, expected는 3이며 PASS함.
- Scores는 [-40,-46,-32,404,-30,24,-14,-28,-16,-42]이며 기존 기준과 exact match함.
- Intermediate checksum 검증 값은 1이며 PASS함.
- Cycles는 29498135, BDOT은 756746, Blocks는 761128임.

## 범위

- 본 결과는 RTL XSim validation 범위임.
- FPGA Multiple-Input execution은 수행하지 않음.
