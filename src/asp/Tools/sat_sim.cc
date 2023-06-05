// __BEGIN_LICENSE__
//  Copyright (c) 2009-2013, United States Government as represented by the
//  Administrator of the National Aeronautics and Space Administration. All
//  rights reserved.
//
//  The NGT platform is licensed under the Apache License, Version 2.0 (the
//  "License"); you may not use this file except in compliance with the
//  License. You may obtain a copy of the License at
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
// __END_LICENSE__

// Tool to create simulated satellite images and/or pinhole cameras for them.
// See the manual for details.

#include <asp/Core/Macros.h>
#include <asp/Core/Common.h>
#include <asp/Core/SatSim.h>

#include <vw/Camera/PinholeModel.h>

namespace po = boost::program_options;
namespace fs = boost::filesystem;

void handle_arguments(int argc, char *argv[], asp::SatSimOptions& opt) {

  double NaN = std::numeric_limits<double>::quiet_NaN();
  po::options_description general_options("General options");
  general_options.add_options()
    ("dem", po::value(&opt.dem_file)->default_value(""), "Input DEM file.")
    ("ortho", po::value(&opt.ortho_file)->default_value(""), "Input georeferenced image file.")
    ("output-prefix,o", po::value(&opt.out_prefix), "Specify the output prefix. All the "
    "files that are saved will start with this prefix.")
    ("camera-list", po::value(&opt.camera_list)->default_value(""),
     "A file containing the list of pinhole cameras to create synthetic images for. "
     "Then these cameras will be used instead of generating them. Specify one file "
     "per line. The options --first, --last, --num, --focal-length, "
     "and --optical-center will be ignored.")
    ("first", po::value(&opt.first)->default_value(vw::Vector3(), ""),
    "First camera position, specified as DEM pixel column and row, and height above "
    "the DEM datum.")
    ("last", po::value(&opt.last)->default_value(vw::Vector3(), ""),
    "Last camera position, specified as DEM pixel column and row, and height above "
    "the DEM datum.")
    ("num", po::value(&opt.num_cameras)->default_value(0),
    "Number of cameras to generate, including the first and last ones. Must be positive. "
    "The cameras are uniformly distributed along the straight edge from first to last (in "
    "projected coordinates).")
    ("first-ground-pos", po::value(&opt.first_ground_pos)->default_value(vw::Vector2(NaN, NaN), ""),
    "Coordinates of first camera ground footprint center (DEM column and row). "
    "If not set, the cameras will look straight down (perpendicular to along "
    "and across track directions).")
    ("last-ground-pos", po::value(&opt.last_ground_pos)->default_value(vw::Vector2(NaN, NaN), ""),
    "Coordinates of last camera ground footprint center (DEM column and row). "
    "If not set, the cameras will look straight down (perpendicular to along "
    "and across track directions).")
    ("focal-length", po::value(&opt.focal_length)->default_value(NaN),
     "Output camera focal length in units of pixel.")
    ("optical-center", po::value(&opt.optical_center)->default_value(vw::Vector2(NaN, NaN),"NaN NaN"),
     "Output camera optical center (image column and row).")
    ("image-size", po::value(&opt.image_size)->default_value(vw::Vector2(NaN, NaN),
      "NaN NaN"),
      "Output camera image size (width and height).")
    ("roll", po::value(&opt.roll)->default_value(NaN),
    "Camera roll angle, in degrees. See the documentation for more details.")
    ("pitch", po::value(&opt.pitch)->default_value(NaN),
    "Camera pitch angle, in degrees.")
    ("yaw", po::value(&opt.yaw)->default_value(NaN),
    "Camera yaw angle, in degrees.")
    ("velocity", po::value(&opt.velocity)->default_value(NaN),
    "Satellite velocity, in meters per second. Used for modeling jitter. A value of "
    "around 8000 m/s is typical for a satellite like SkySat in Sun-synchronous orbit "
    "(90 minute period) at an altitude of about 450 km. For WorldView, the velocity "
    "is around 7500 m/s, with a higher altitude and longer period.")
    ("horizontal-uncertainty", po::value(&opt.horizontal_uncertainty)->default_value(vw::Vector3(NaN, NaN, NaN)),
    "Camera horizontal uncertainty on the ground, in meters, at nadir orientation. "
    "Specify as three numbers, used for roll, pitch, and yaw. The "
    "angular uncertainty in the camera orientation for each of these angles "
    "is found as tan(angular_uncertainty) "
    "= horizontal_uncertainty / satellite_elevation_above_datum, then converted to degrees.")
    ("jitter-frequency", po::value(&opt.jitter_frequency)->default_value(NaN),
    "Jitter frequency, in Hz. Used for modeling jitter (satellite vibration). "
    "The jitter amplitude will be the angular horizontal uncertainty (see "
    "--horizontal-uncertainty).")
    ("no-images", po::bool_switch(&opt.no_images)->default_value(false)->implicit_value(true),
     "Create only cameras, and no images. Cannot be used with --camera-list.")
    ("dem-height-error-tol", po::value(&opt.dem_height_error_tol)->default_value(0.001),
     "When intersecting a ray with a DEM, use this as the height error tolerance "
     "(measured in meters). It is expected that the default will be always good enough.")
    ;
  general_options.add(vw::GdalWriteOptionsDescription(opt));

  po::options_description positional("");
  po::positional_options_description positional_desc;

  std::string usage("--dem <dem file> --ortho <ortho image file> "
                    "[other options]");

  bool allow_unregistered = false;
  std::vector<std::string> unregistered;
  po::variables_map vm =
    asp::check_command_line(argc, argv, opt, general_options, general_options,
                            positional, positional_desc, usage,
                            allow_unregistered, unregistered);
  if (opt.dem_file == "" || opt.ortho_file == "")
    vw::vw_throw(vw::ArgumentErr() << "Missing input DEM and/or ortho image.\n");
  if (opt.out_prefix == "")
    vw::vw_throw(vw::ArgumentErr() << "Missing output prefix.\n");
  if (std::isnan(opt.image_size[0]) || std::isnan(opt.image_size[1]))
    vw::vw_throw(vw::ArgumentErr() << "The image size must be specified.\n");

  if (opt.camera_list != "" && opt.no_images)
    vw::vw_throw(vw::ArgumentErr() << "The --camera-list and --no-images options "
      "cannot be used together.\n");

  if (opt.camera_list == "") {
    if (opt.first == vw::Vector3() || opt.last == vw::Vector3())
      vw::vw_throw(vw::ArgumentErr() << "The first and last camera positions must be "
        "specified.\n");

    if (opt.first[2] != opt.last[2])
      vw::vw_out() << "Warning: The first and last camera positions have different "
                   << "heights above the datum. This is supported but is not usual. "
                   << "Check your inputs.\n";

    if (opt.num_cameras < 2)
      vw::vw_throw(vw::ArgumentErr() << "The number of cameras must be at least 2.\n");

    // Validate focal length, optical center, and image size
    if (std::isnan(opt.focal_length))
      vw::vw_throw(vw::ArgumentErr() << "The focal length must be positive.\n");
    if (std::isnan(opt.optical_center[0]) || std::isnan(opt.optical_center[1]))
      vw::vw_throw(vw::ArgumentErr() << "The optical center must be specified.\n");

    // Either both first and last ground positions are specified, or none.
    if (std::isnan(norm_2(opt.first_ground_pos)) != 
      std::isnan(norm_2(opt.last_ground_pos)))
      vw::vw_throw(vw::ArgumentErr() << "Either both first and last ground positions "
        "must be specified, or none.\n");

    // Check that either all of roll, pitch, and yaw are specified, or none.
    int ans = int(std::isnan(opt.roll)) +
              int(std::isnan(opt.pitch)) +
              int(std::isnan(opt.yaw));
    if (ans != 0 && ans != 3)
      vw::vw_throw(vw::ArgumentErr() << "Either all of roll, pitch, and yaw must be "
        "specified, or none.\n");
  }

  int ans = int(!std::isnan(opt.jitter_frequency)) +
            int(!std::isnan(opt.velocity)) +
            int(!std::isnan(opt.horizontal_uncertainty[0])) +
            int(!std::isnan(opt.horizontal_uncertainty[1])) +
            int(!std::isnan(opt.horizontal_uncertainty[2]));
  if (ans != 0 && ans != 5)
    vw::vw_throw(vw::ArgumentErr() << "Either all of jitter-frequency, velocity, and "
      "horizontal uncertainty must be specified, or none.\n");
  
  bool have_roll_pitch_yaw = !std::isnan(opt.roll) && !std::isnan(opt.pitch) &&
      !std::isnan(opt.yaw);
  if (ans != 0 && !have_roll_pitch_yaw)
    vw::vw_throw(vw::ArgumentErr() << "Modelling jitter requires specifying --roll, --pitch, and --yaw.\n");

  if (opt.camera_list != "" && ans != 0) 
    vw::vw_throw(vw::ArgumentErr() << "The --camera-list, --jitter-frequency, "
      "--velocity, and --horizontal-uncertainty options cannot be used together.\n");

  if (opt.velocity <= 0)
    vw::vw_throw(vw::ArgumentErr() << "The satellite velocity must be positive.\n");

  if (opt.horizontal_uncertainty[0] < 0 || opt.horizontal_uncertainty[1] < 0 ||
      opt.horizontal_uncertainty[2] < 0)
    vw::vw_throw(vw::ArgumentErr() << "The horizontal uncertainty must be non-negative.\n");

  if (opt.jitter_frequency <= 0)
    vw::vw_throw(vw::ArgumentErr() << "The jitter frequency must be positive.\n");

  // Create the output directory based on the output prefix
  vw::create_out_dir(opt.out_prefix);

  return;
}

int main(int argc, char *argv[]) {

  asp::SatSimOptions opt;
  try {
    handle_arguments(argc, argv, opt);

    // Read the DEM
    vw::ImageViewRef<vw::PixelMask<float>> dem;
    float dem_nodata_val = -std::numeric_limits<float>::max(); // will change
    vw::cartography::GeoReference dem_georef;
    asp::readGeorefImage(opt.dem_file, dem_nodata_val, dem_georef, dem);

    // Read the ortho image
    vw::ImageViewRef<vw::PixelMask<float>> ortho;
    float ortho_nodata_val = -std::numeric_limits<float>::max(); // will change
    vw::cartography::GeoReference ortho_georef;
    asp::readGeorefImage(opt.ortho_file, ortho_nodata_val, ortho_georef, ortho);

    std::vector<std::string> cam_names;
    std::vector<vw::camera::PinholeModel> cams;
    bool external_cameras = false;
    if (!opt.camera_list.empty()) {
      // Read the cameras
      asp::readCameras(opt, cam_names, cams);
      external_cameras = true;
    } else {
     // Generate the cameras   
      std::vector<vw::Vector3> trajectory(opt.num_cameras);
      // vector of rot matrices
      std::vector<vw::Matrix3x3> cam2world(opt.num_cameras);
      asp::calcTrajectory(opt, dem_georef, dem,
        // Outputs
        trajectory, cam2world);
        // Generate cameras
        asp::genCameras(opt, trajectory, cam2world, cam_names, cams);
    }

    // Generate images
    if (!opt.no_images)
      asp::genImages(opt, external_cameras, cam_names, cams, dem_georef, dem, 
        ortho_georef, ortho, ortho_nodata_val);

  } ASP_STANDARD_CATCHES;

  return 0;
}