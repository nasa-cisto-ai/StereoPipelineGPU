.. _pleiades:

Pleiades
--------

ASP supports the 1A/1B and NEO satellites from Airbus Pleiades. 
For NEO, see :numref:`pleiades_neo` for additional notes.

The Airbus Pleiades data have both an exact linescan camera model
and an approximate RPC model (:numref:`rpc`). These are stored in separate files. The
names for these start with "DIM" and "RPC", respectively, and end with
".XML". ASP supports both kinds. The USGS CSM library (:numref:`csm`) is 
used for linescan models.

See :numref:`airbus_tiled` if the input images arrive in multiple
tiles. See :numref:`jitter_pleiades` for an example of solving for
jitter for these cameras.

If desired to process a Pleiades triplet, bundle adjustment (:numref:`bundle_adjust`) 
is very recommended before stereo. It should be run as::

    bundle_adjust -t pleiades --camera-weight 0 --tri-weight 0.1 \
      <images> <cameras> -o ba/run

Then, pass ``--bundle-adjust-prefix ba/run`` to ``parallel_stereo`` in 
all examples further down.

With the exact models, the stereo command is::

    parallel_stereo -t pleiades --stereo-algorithm asp_mgm  \
        --subpixel-mode 9                                   \
        left.tif right.tif left_exact.xml right_exact.xml   \
        results/run

See :numref:`nextsteps` for a discussion about various
speed-vs-quality choices for stereo.

For the RPC model the option ``-t rpc`` should be used and the correct
camera files should be passed in. If the ``-t`` option is not
specified, it will be auto-guessed based on the content of the camera
files provided as inputs.

For Pleiades exact linescan camera models the atmospheric correction
and velocity aberration corrections (:numref:`sensor_corrections`) are
disabled. This ensures that the exact and RPC camera models agree (see
below).

ASP supports running stereo with mapprojected Pleiades images
(:numref:`mapproj-example`). All input images must be mapprojected at
the same resolution (which is comparable with the ground sample
distance). The same camera models must be used for mapprojection
as for stereo, so one should not mix the exact and RPC cameras.
Example::

    mapproject --tr 0.000009 -t pleiades                        \
      ref_dem.tif left.tif left_exact.xml left_map.tif 
    mapproject --tr 0.000009 -t pleiades                        \
      ref_dem.tif right.tif right_exact.xml right_map.tif
    parallel_stereo --stereo-algorithm asp_mgm                  \
      left_map.tif right_map.tif left_exact.xml right_exact.xml \
      run_map/run ref_dem.tif
   point2dem run_map/run-PC.tif 

Here it is assumed the images are far from the poles, the input DEM
has the longlat projection, and the grid size (``--tr``) is in degrees
(the value 0.000009 may need adjustment). Otherwise, a polar or UTM
projection needs to be used (option ``--t_srs``) and the grid size
should be set to the known image ground sample distance in
meters.

To compare the linescan and RPC models, run ``cam_test``
(:numref:`cam_test`) as::

     cam_test --image img.tif --cam1 cam_exact.xml --cam2 cam_rpc.xml \
       --session1 pleiades --session2 rpc

This should give great agreement when it comes to pixels projected
from one camera to the ground, then reprojected back to the other
one::

    cam1 to cam2 pixel diff
    Max:    0.00304066

    cam2 to cam1 pixel diff
    Max:    0.00296764

The camera centers computed by the two methods won't agree, because
the RPC camera model does not store the camera center. ASP then
substitutes it with an estimated point on the ray from the camera
center to the ground. This disagreement is not an issue in practice.

Commands similar to the above can be used to compare the exact and RPC
cameras not to each other but against themselves. This tool will also
print timing information for the operation of projecting a pixel to
the ground and back.

.. _pleiades_neo:

Pleiades NEO
~~~~~~~~~~~~

Several peculiarities make the Pleiades NEO data different from 1A/1B (:numref:`pleiades`):

- The tabulated positions and orientations may start slightly after the first image line and end slightly before the last image line. If these scenarios are encountered, linear extrapolation based on two immediate values is used to fill in the missing values and a warning is printed for each such operation.
- There is no field for standard deviation of the ground locations of pixels projected from the cameras, so error propagation is not possible unless such a value is specified manually (:numref:`error_propagation`).
- The RPC camera models for a stereo triplet can be rather inconsistent with each other, resulting in large triangulation error. It is suggested to use instead the exact linescan camera model.

.. _airbus_tiled:

Pleiades tiled images
~~~~~~~~~~~~~~~~~~~~~

With some Airbus Pleiades data, each of the left and right images
may arrive broken up into .TIF or .JP2 tiles, with names ending in
R1C1.tif, R2C1.tif, etc.

These need to be mosaicked before being used. That can be done as
follows (individually for the left and right stereo image), using
``gdalbuildvrt`` (:numref:`gdal_tools`)::

      gdalbuildvrt vrt.tif *R*C*.tif

This expects any input .tif file to have an associated .tfw (.TFW) file
containing information about how the tiles should be combined.

If both PAN and multispectral tiles are present, use only the PAN ones.

This will create a virtual mosaic, which is just a plain text file
having pointers to the subimages. ASP can use that one as if it was a real image.
If desired, an actual self-contained image can be produced with::

    gdal_translate -co TILED=YES -co BLOCKXSIZE=256 -co BLOCKYSIZE=256 \
      -co BIGTIFF=IF_SAFER vrt.tif image.tif

Note that the size of this image will be comparable to the sum of sizes
of the original tiles.

The Orfeo Toolbox provides functionality for stitching such images as well.

