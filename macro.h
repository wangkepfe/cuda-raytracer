#pragma once

#define KERNAL_LOOP 10

#define WIDTH 512 
#define HEIGHT 384

#define SAMPLES 512

#define BLOCK_SIZE 8
#define NUM_BLOCKS WIDTH*HEIGHT/BLOCK_SIZE/BLOCK_SIZE

#define RAY_BOUNCE 4

#define M_PI 3.14159265359f
#define M_INF 1e20f
#define M_EPSILON 0.0001f