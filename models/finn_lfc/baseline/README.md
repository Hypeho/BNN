# FINN LFC-W1A1 RV32I

FINN `LFCW1A1.onnx`의 weight를 1-bit로 pack하고 BN+Sign을 integer
match-count threshold와 polarity로 변환한 전체 RV32I inference이다.

```bash
bash script/build.sh
python3 analysis/profile_lfc.py \
  --profiler ../260624_eBNN_Binary_MNIST/analysis/rv32i_profile.py \
  --elf build/finn_lfc.elf --imem build/imem.hex --dmem build/dmem.hex
```

생성된 `generated/lfc_params.h`가 있으면 ONNX Python 환경 없이도 다시
컴파일할 수 있다. 파라미터를 다시 생성하려면 ONNX/ONNX Runtime 환경을
지정하고 `REGENERATE_PARAMS=1`로 build한다.

검증 결과는 ONNX class 5, RV32I class 5이며, 추가 random binary input
8개에서도 packed Python inference와 ONNX의 class가 일치했다.
