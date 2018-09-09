/***********************************
 *                                 *
 *      A very n1ce raytracer      *
 *                                 *
 ***********************************/
 
// Author: Ke Wang
// Summer 2018

// C/C++
#include <iostream>
#include <time.h>

// CUDA
#include <cuda_runtime.h>
#include <vector_types.h>
#include <device_launch_parameters.h>
#include <curand.h>
#include <curand_kernel.h>

// Macro and constants
#include "macro.h"
#include "constants.cuh"

// C++ header libs
#include "io_utils.h"
#include "obj_loader.h"

// CUDA header libs
#include "geometry.cuh"
#include "geometryIntersect.cuh"
#include "implicitGeometry.cuh"
#include "material.cuh"
#include "surface.cuh"
#include "meshGeometry.cuh"

struct Attr{
    uint numberOfObject;

    // implicit primitives
    Sphere* spheres;
    AxisAlignedBoundingBox* aabbs;

    // array of vertices, faces and meshIndexOnlys
    Meshes_SOA meshSOA;

    // mat
    Material* materials;

    // geo
    Geometry* geometries;
};

__global__ void renderKernal (
    float3 *output,
    uint2 patch_offset,
    Attr attr, 
    curandState_t* randstates)
{
    uint x = blockIdx.x*blockDim.x + threadIdx.x;   
    uint y = blockIdx.y*blockDim.y + threadIdx.y;
    uint idx = (PATCH_HEIGHT - y - 1) * PATCH_WIDTH + x;
    uint randStateidx = threadIdx.y * BLOCK_SIZE + threadIdx.x;

    uint realX = patch_offset.x + x;   
    uint realY = patch_offset.y + y;

    float3 deltaX = make_float3(WIDTH * camFov / HEIGHT, 0.0f, 0.0f);
    float3 deltaY = make_float3(0.0f, camFov, 0.0f);

    float3 finalColor = make_float3(0.0f, 0.0f, 0.0f);

    float3 rayDirection = normalize(camDir + deltaX * (realX * 2.0f / WIDTH - 1.0f) + deltaY * (realY * 2.0f / HEIGHT - 1.0f));

    for (uint s = 0; s < SAMPLES; s++) {//sample
        Ray currentRay {camOrig, rayDirection};

        float3 accumulativeColor = make_float3(0.0f, 0.0f, 0.0f);
        float3 colorMask = make_float3(1.0f, 1.0f, 1.0f);

        for (uint bounces = 0; bounces < RAY_BOUNCE; bounces++) {//bounce
            float3 hitPoint;
            float3 normalAtHitPoint;
            bool isIntoSurface = true;

            float nearestIntersectionDistance = M_INF;
            bool hitEmptyVoidSpace = true;
            int hitObjectMaterialIdx = 0;

            for (uint objectIdx = 0; objectIdx < attr.numberOfObject; ++objectIdx) {// scene intersection
                Geometry geometry = attr.geometries[objectIdx];

                if (geometry.geometryType == SPHERE) {
                    Sphere sphere = attr.spheres[geometry.geometryIdx];
                    float distanceToObject = intersectSphereRay(sphere, currentRay);
    
                    if (distanceToObject > M_EPSILON && distanceToObject < nearestIntersectionDistance) {
                        hitEmptyVoidSpace = false;
                        nearestIntersectionDistance = distanceToObject;

                        hitPoint = currentRay.orig + currentRay.dir * distanceToObject;
                        normalAtHitPoint = getSphereNormal(hitPoint, sphere.orig, currentRay.dir, isIntoSurface);
                        hitObjectMaterialIdx = geometry.materialIdx;
                    }
                } 
                else if (geometry.geometryType == AABB) {
                    AxisAlignedBoundingBox aabb = attr.aabbs[geometry.geometryIdx];
                    float distanceToObject = intersectAABBRayBothSide(aabb, currentRay);
    
                    if (distanceToObject > M_EPSILON && distanceToObject < nearestIntersectionDistance) {
                        hitEmptyVoidSpace = false;
                        nearestIntersectionDistance = distanceToObject;

                        hitPoint = currentRay.orig + currentRay.dir * distanceToObject;
                        normalAtHitPoint = getAABBNormal(hitPoint, aabb, currentRay.dir, isIntoSurface);
                        hitObjectMaterialIdx = geometry.materialIdx;
                    }                    
                }
                else if (geometry.geometryType == MESH) {
                    Mesh mesh;
                    getMeshFromSOA(attr.meshSOA, geometry.geometryIdx, mesh);
                    for (uint i = 0; i < mesh.vertexNum; ++i) {
                        printf("%f %f %f\n", mesh.vertices[i].x, mesh.vertices[i].y, mesh.vertices[i].z);
                    }

                    float distanceToObject = RayMeshIntersection(normalAtHitPoint, isIntoSurface, mesh, currentRay);

                    if (distanceToObject > M_EPSILON && distanceToObject < nearestIntersectionDistance) {
                        hitEmptyVoidSpace = false;
                        nearestIntersectionDistance = distanceToObject;
                        hitPoint = currentRay.orig + currentRay.dir * distanceToObject;
                        hitObjectMaterialIdx = geometry.materialIdx;
                    }
                }
            }// end of scene intersection

            if (hitEmptyVoidSpace) {
                if (dot(currentRay.dir, sunDir) > sunSize)
                    accumulativeColor += colorMask * sunColor;
                else if (bounces == 0)
                    accumulativeColor += colorMask * skyColor;
                else
                    accumulativeColor += colorMask * mistColor;

                break;// break out of bounce
            }

            // surface
            Material material = attr.materials[hitObjectMaterialIdx];
            accumulativeColor += colorMask * material.colorEmission;

            if (material.surfaceType == DIFFUSE) {
                diffuseSurface(
                    currentRay,
                    colorMask,
                    
                    hitPoint,
                    normalAtHitPoint,
                    material.surfaceColor,
                    randstates,
                    randStateidx
                );
            }
            else if (material.surfaceType == SPECULAR) {
                specularSurface(
                    currentRay,
                    colorMask,

                    hitPoint,
                    normalAtHitPoint,
                    material.surfaceColor,
                    randstates,
                    randStateidx
                );
            }
            else if (material.surfaceType == MIRROR) {
                mirrorSurface(
                    currentRay,
                    colorMask,

                    hitPoint,
                    normalAtHitPoint,
                    material.surfaceColor
                );
            }
            else if (material.surfaceType == TRANSPARENT) {
                transparentSurface(
                    currentRay,
                    colorMask,

                    isIntoSurface,
                    hitPoint,
                    normalAtHitPoint,
                    randstates,
                    randStateidx
                );
            }
            
        }//end of bounce
        finalColor += accumulativeColor / SAMPLES;

    }//end of sample

    output[idx] = make_float3(clamp(finalColor.x, 0.0f, 1.0f), clamp(finalColor.y, 0.0f, 1.0f), clamp(finalColor.z, 0.0f, 1.0f));
}

__global__ void initRandStates(uint seed, curandState_t* randstates) {
    uint idx = threadIdx.y * BLOCK_SIZE + threadIdx.x;
    curand_init(seed, idx, 0, &randstates[idx]);
}

int main(){
    // define dim
    dim3 block(BLOCK_SIZE, BLOCK_SIZE, 1);   
    dim3 grid(PATCH_WIDTH / block.x, PATCH_HEIGHT / block.y, 1);

    // rand states
    curandState_t* randstates_d;
    cudaMalloc((void**) &randstates_d, BLOCK_SIZE * BLOCK_SIZE * sizeof(curandState_t));
    initRandStates<<<1, block>>>(time(NULL), randstates_d);

    // build the scene
    AxisAlignedBoundingBox myHouseAABB = AxisAlignedBoundingBox {float3{-80.0f, -40.0f, -10.0f},float3{80.0f, 80.0f, 200.0f}};
    Sphere sphereOnTheCeiling = Sphere {float3{0.0f, 90.0f, 180.0f} ,20.0f};

    Mesh testMesh = loadObj("basicCube.obj");

    scaleMesh(testMesh, float3{5.0f, 5.0f, 5.0f});
    translateMesh(testMesh, float3{0.0f, -10.0f, 120.0f});

    Material whiteDiffuse {DIFFUSE, float3{0.0f, 0.0f, 0.0f}, float3{0.75f, 0.75f, 0.75f}};
    Material whiteLight {DIFFUSE, float3{1.0f, 1.0f, 1.0f}, float3{0.75f, 0.75f, 0.75f}};

    Sphere spheres[] {
        sphereOnTheCeiling
    };
    AxisAlignedBoundingBox aabbs[] {
        myHouseAABB
    };
 //   Mesh *meshes;
    Mesh meshes[] {
        testMesh
    };
    Material materials[] {
        whiteDiffuse,
        whiteLight
    };
    Geometry myHouse {AABB, 0, 0};
    Geometry myCeilingLight {SPHERE, 0, 1};
    Geometry myNiceMesh {MESH, 0, 0};

    Geometry geometries[] {
        myHouse,
        myCeilingLight,
        myNiceMesh
    };
    // copy data to cuda
    CUDA_MALLOC_MEMCPY_HOST_TO_DEVICE(Sphere, spheres_d, spheres)
    CUDA_MALLOC_MEMCPY_HOST_TO_DEVICE(AxisAlignedBoundingBox, aabbs_d, aabbs)

    Meshes_SOA meshSOA;

    convertMeshAOSToSOA(meshes, sizeof(meshes) / sizeof(Mesh), meshSOA);

    CUDA_MALLOC_MEMCPY_HOST_TO_DEVICE(Vertex, vertices_d, meshSOA.vertices)
    CUDA_MALLOC_MEMCPY_HOST_TO_DEVICE(Face, faces_d, meshSOA.faces)
    CUDA_MALLOC_MEMCPY_HOST_TO_DEVICE(Mesh_IndexOnly, meshes_d, meshSOA.meshes)

    Meshes_SOA meshSOA_d {vertices_d, faces_d, meshes_d};

    deleteMeshSOA(meshSOA);

    CUDA_MALLOC_MEMCPY_HOST_TO_DEVICE(Material, materials_d, materials)
    CUDA_MALLOC_MEMCPY_HOST_TO_DEVICE(Geometry, geometries_d, geometries)

    Attr attr {
        sizeof(geometries) / sizeof(Geometry), 

        spheres_d, 
        aabbs_d,

        meshSOA_d,

        materials_d, 
        geometries_d
    };

    // start rendering
    float3* output = new float3[WIDTH * HEIGHT];
    for (uint i = 0; i < WIDTH * HEIGHT; ++i) output[i] = make_float3(0.0f, 0.0f, 0.0f);
    float3* output_patch = new float3[PATCH_WIDTH * PATCH_HEIGHT];
    float3* output_d;
    cudaMalloc(&output_d, PATCH_WIDTH * PATCH_HEIGHT * sizeof(float3));

    uint progressRecord = 0;
    printf("Rendering...0%%\n");

    for (uint patch_i = 0; patch_i < PATCH_NUM_X; ++patch_i) {
        for (uint patch_j = 0; patch_j < PATCH_NUM_Y; ++patch_j) {
            for (uint kernalLoop_i = 0; kernalLoop_i < KERNAL_LOOP; ++kernalLoop_i) {   
                renderKernal <<< grid, block >>> (
                    output_d,
                    uint2{patch_i*PATCH_WIDTH, (PATCH_NUM_Y - patch_j - 1)*PATCH_HEIGHT},
                    attr,
                    randstates_d);
                cudaMemcpy(output_patch, output_d, PATCH_WIDTH * PATCH_HEIGHT * sizeof(float3), cudaMemcpyDeviceToHost);
                
                for (uint i = 0; i < PATCH_WIDTH; ++i) {
                    for (uint j = 0; j < PATCH_HEIGHT; ++j) {
                        output[(patch_j*PATCH_HEIGHT + j) * WIDTH + patch_i*PATCH_WIDTH + i] += output_patch[j * PATCH_WIDTH + i];
                    }
                }  

                uint progressPercent = ((patch_i * PATCH_NUM_Y + patch_j) * KERNAL_LOOP + kernalLoop_i) * 10 / PATCH_NUM_X / PATCH_NUM_Y / KERNAL_LOOP;
                if (progressRecord != progressPercent) {
                    progressRecord = progressPercent;
                    printf("Rendering...%d0%%\n", progressRecord);
                }
            }
        }
    }

    for (uint i = 0; i < WIDTH * HEIGHT; ++i) output[i] /= KERNAL_LOOP;

    printf("Rendering...100%%\n");
    printf("Done!\n");

    // output
    writeToPPM("result.ppm", WIDTH, HEIGHT, output);

    // clean
    cudaFree(spheres_d); 
    cudaFree(aabbs_d);
    
    cudaFree(vertices_d);
    cudaFree(faces_d);
    cudaFree(meshes_d);

    cudaFree(materials_d);
    cudaFree(geometries_d);

    cudaFree(output_d);  

    cudaFree(randstates_d);

    delete[] output;
    delete[] output_patch;
}