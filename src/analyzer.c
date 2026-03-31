#include <stdint.h>
#include <math.h>
#include "kissfft/kiss_fft.h"

__attribute__((visibility("default"))) __attribute__((used))

void frequency_audio(const int16_t* inputData, float* outputData, int n) {
    kiss_fft_cfg cfg = kiss_fft_alloc(n, 0, NULL, NULL);
    if (cfg == NULL) return;

    kiss_fft_cpx* cin = (kiss_fft_cpx*)malloc(sizeof(kiss_fft_cpx) * n);
    kiss_fft_cpx* cout = (kiss_fft_cpx*)malloc(sizeof(kiss_fft_cpx) * n);

    for (int i = 0; i < n; i++) {
        float window = 0.5f * (1.0f - cosf(2.0f * 3.14159265f * i / (n-1)));
        cin[i].r = (float)inputData[i] * window;
        cin[i].i = 0;
    }

    kiss_fft(cfg, cin, cout);

    for (int i = 0; i < n / 2; i++) {
        float re = cout[i].r;
        float im = cout[i].i;
        outputData[i] = sqrtf(re * re + im * im);
    }

    free(cin);
    free(cout);
    free(cfg);
}