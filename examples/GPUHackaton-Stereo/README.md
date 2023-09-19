# GPU Hackaton: Stereo GPU Implementation

## Regression Test #1: Small Use Case Example

This will be the main test we will be using to test our acceleration development efforts.
This test is constrained so development efforts can be tested fairly quickly.
The example below is just to show familiarity with the process of running the DEM
generation.

1. Download the Binary

```bash
wget https://github.com/NeoGeographyToolkit/StereoPipeline/releases/download/2023-09-03-daily-build/StereoPipeline-3.4.0-alpha-2023-09-03-x86_64-Linux.tar.bz2
tar xvf StereoPipeline-3.4.0-alpha-2023-09-03-x86_64-Linux.tar.bz2
./StereoPipeline-3.4.0-alpha-2023-09-03-x86_64-Linux/bin/stereo --help
```

2. Download the Data

```bash
wget https://github.com/NeoGeographyToolkit/StereoPipelineSolvedExamples/releases/download/ASTER/ASTER_example.tar
tar xfv ASTER_example.tar
```

3. Setup binary path

```bash
export PATH=${PATH}:/path/to/StereoPipeline/bin
```

for example:

```bash
export PATH=${PATH}:$NOBACKUP/projects/HackWeek2023/StereoPipeline-3.4.0-alpha-2023-09-03-x86_64-Linux/bin
```

4. Run parallel_stereo

```bash
parallel_stereo -t aster --subpixel-mode 3 ASTER_example/aster-Band3N.tif ASTER_example/aster-Band3B.tif ASTER_example/aster-Band3N.xml ASTER_example/aster-Band3B.xml out_stereo/run
point2dem -r earth --tr 0.0002777 out_stereo/run-PC.tif
```

## Regression Test #1: Individual Steps

No logs for Blend (Step 2) and Sub-pixel refinement (Step 3) calls. All other calls are listed below.
Using each one of these algorithms on their own might be a better way of testing
individual functionalities across the software.

### Step 0 Preprocessing

```bash
stereo_pprc -t aster --subpixel-mode 3 --corr-seed-mode 1 --threads 10 ASTER_example/aster-Band3N.tif ASTER_example/aster-Band3B.tif ASTER_example/aster-Band3N.xml ASTER_example/aster-Band3B.xml out_stereo/run
```

### Step 1 Correlation

```bash
stereo_corr -t aster --subpixel-mode 3 --corr-seed-mode 1 --compute-low-res-disparity-only ASTER_example/aster-Band3N.tif ASTER_example/aster-Band3B.tif ASTER_example/aster-Band3N.xml ASTER_example/aster-Band3B.xml out_stereo/run
```

### Step 4 Outlier rejection

```bash
stereo_fltr -t aster --subpixel-mode 3 --corr-seed-mode 1 --threads 10 ASTER_example/aster-Band3N.tif ASTER_example/aster-Band3B.tif ASTER_example/aster-Band3N.xml ASTER_example/aster-Band3B.xml out_stereo/run
```

### Step 5 Triangulation

```bash
stereo_tri -t aster --subpixel-mode 3 --corr-seed-mode 1 --compute-point-cloud-center-only --threads 10 ASTER_example/aster-Band3N.tif ASTER_example/aster-Band3B.tif ASTER_example/aster-Band3N.xml ASTER_example/aster-Band3B.xml out_stereo/run
```

## Software Development Dependencies

We will need to develop and compile some of these modules given that the current
StereoPipeline software comes as a binary. The development environment looks as follows.

### Container

```bash
```

### Anaconda Environment

Installing local anaconda environment on NAS

```bash
conda env create -n asp_deps -f asp_deps_3.3.0_linux_env.yaml
source activate asp_deps
conda install -c conda-forge compilers
conda install -c conda-forge "cmake>=3.15.5" pbzip2 chrpath
```

### Mamba Environment

Installing local micromamba env on NCCS PRISM GPU compute node

```bash
module load cmake
module load mamba
module load nvidia

mkdir /explore/nobackup/people/<userID>/micromamba
ln -s /explore/nobackup/people/<userID>/micromamba ~/micromamba

mamba config set channel_priority flexible
mamba create -n aspv2 -f asp_deps_3.3.0_linux_env.yaml

eval "$(micromamba shell hook --shell=bash)"

micromamba activate aspv2

mamba install -c conda-forge compilers
mamba install -c conda-forge "cmake>=3.15.5" pbzip2 chrpath
```