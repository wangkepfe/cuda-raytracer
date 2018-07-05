#ifndef __IO_UTILS_H__
#define __IO_UTILS_H__

#include <iostream>
#include "cuda_runtime.h"
#include "cutil_math.h"

inline int toInt(float x){ return int(pow(clamp(x, 0.0f, 1.0f), 1 / 2.2) * 255 + .5); }  

inline void writeToPPM(const char* fname, int width, int height, float3* buffer){
    FILE *f = fopen(fname, "w");          
    fprintf(f, "P3\n%d %d\n%d\n", width, height, 255);
    for (int i = 0; i < width * height; i++)  // loop over pixels, write RGB values
        fprintf(f, "%d %d %d ", 
            toInt(buffer[i].x),
            toInt(buffer[i].y),
            toInt(buffer[i].z));
    fclose(f);
}

#endif