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

// Tool to compare two camera models for the same image. For example,
// compare ISIS to CSM, linescan to RPC (for DG, PeruSat, or
// Pleiades), Optical bar vs pinhole (with the latter created with
// convert_pinhole_model).

// For each camera model find the camera center and ray direction at a
// set of sampled pixels, then by projecting pixels to the ground
// using the cam1 camera and back-projecting the resulting points into
// the cam2 camera, then doing this in reverse.

#include <asp/Core/Macros.h>
#include <asp/Core/Common.h>
#include <asp/Core/StereoSettings.h>
#include <asp/Sessions/StereoSession.h>
#include <asp/Sessions/StereoSessionFactory.h>
#include <asp/Camera/RPCModel.h>
#include <asp/Camera/CsmModel.h>
#include <asp/IsisIO/IsisCameraModel.h>
#include <asp/Camera/Covariance.h>

#include <vw/Core/Stopwatch.h>

using namespace vw;
using namespace vw::cartography;
namespace po = boost::program_options;
namespace fs = boost::filesystem;

typedef boost::scoped_ptr<asp::StereoSession> SessionPtr;

struct Options : vw::GdalWriteOptions {
  std::string image_file, cam1_file, cam2_file, session1, session2, bundle_adjust_prefix, datum;
  int sample_rate; // use one out of these many pixels
  double subpixel_offset, height_above_datum;
  bool enable_correct_velocity_aberration, enable_correct_atmospheric_refraction,
    print_per_pixel_results, dg_use_csm, dg_vs_csm, test_error_propagation;
  vw::Vector2 single_pixel;

  Options() {}
};

void handle_arguments(int argc, char *argv[], Options& opt) {

  double nan = std::numeric_limits<double>::quiet_NaN();
  po::options_description general_options("General options");
  general_options.add_options()
    ("image", po::value(&opt.image_file),  "Image file.")
    ("cam1",  po::value(&opt.cam1_file),   "Camera 1 file.")
    ("cam2",  po::value(&opt.cam2_file),   "Camera 2 file.")
    ("session1", po::value(&opt.session1),
     "Session to use for camera 1 (if not provided it will be guessed).")
    ("session2", po::value(&opt.session2),
     "Session to use for camera 2 (if not provided it will be guessed).")
    ("sample-rate",   po::value(&opt.sample_rate)->default_value(100),
     "Use one out of these many pixels when sampling the image.")
    ("subpixel-offset",   po::value(&opt.subpixel_offset)->default_value(0.0),
     "Add to each integer pixel this offset (in x and y) when sampling the image.")
    ("single-pixel",   po::value(&opt.single_pixel)->default_value(Vector2(nan, nan)),
     "Instead of sampling pixels from the image use only this pixel.")
    ("print-per-pixel-results", po::bool_switch(&opt.print_per_pixel_results)->default_value(false)->implicit_value(true),
     "Print the results at each pixel.")
    ("height-above-datum",   po::value(&opt.height_above_datum)->default_value(0.0),
     "Let the ground be obtained from the datum for this camera by "
     "adding to its radii this value (the units are meters).")
    ("datum", po::value(&opt.datum),
     "Set the datum. This will override the datum from the input cameras. Usually needed "
     "only for Pinhole cameras for non-Earth planets, when the camera does not have "
     "the datum information. Options: WGS_1984, D_MOON (1,737,400 meters), "
     "D_MARS (3,396,190 meters), MOLA (3,396,000 meters), NAD83, WGS72, "
     "and NAD27. Also accepted: Earth (=WGS_1984), Mars (=D_MARS), Moon (=D_MOON).")
    ("enable-correct-velocity-aberration", po::bool_switch(&opt.enable_correct_velocity_aberration)->default_value(false)->implicit_value(true),
     "Turn on velocity aberration correction for Optical Bar and non-ISIS linescan cameras. This option impairs the convergence of bundle adjustment.")
    ("enable-correct-atmospheric-refraction", po::bool_switch(&opt.enable_correct_atmospheric_refraction)->default_value(false)->implicit_value(true),
     "Turn on atmospheric refraction correction for Optical Bar and non-ISIS linescan cameras. This option impairs the convergence of bundle adjustment.")
    ("dg-use-csm", po::bool_switch(&opt.dg_use_csm)->default_value(false)->implicit_value(true),
     "Use the CSM model with DigitalGlobe linescan cameras (-t dg). No corrections are done for velocity aberration or atmospheric refraction.")
    ("dg-vs-csm", po::bool_switch(&opt.dg_vs_csm)->default_value(false)->implicit_value(true),
     "Compare projecting into the camera without and with using the CSM model for Digital Globe.")
    ("bundle-adjust-prefix", po::value(&opt.bundle_adjust_prefix),
     "Adjust the cameras using this prefix.")
    ("test-error-propagation", po::bool_switch(&opt.test_error_propagation)->default_value(false)->implicit_value(true),
     "Test computing the stddev (see --propagate-errors). This is an undocumented developer option.")
    ;
  general_options.add(vw::GdalWriteOptionsDescription(opt));

  po::options_description positional("");
  po::positional_options_description positional_desc;

  std::string usage("--image <image file> --cam1 <camera 1 file> --cam2 <camera 2 file> "
                    "[other options]");

  bool allow_unregistered = false;
  std::vector<std::string> unregistered;
  po::variables_map vm =
    asp::check_command_line(argc, argv, opt, general_options, general_options,
                            positional, positional_desc, usage,
                            allow_unregistered, unregistered);

  if (opt.image_file == "" || opt.cam1_file == "" || opt.cam2_file == "")
    vw_throw(ArgumentErr() << "Not all inputs were specified.\n" << usage << general_options);

  if (opt.sample_rate <= 0)
    vw_throw(ArgumentErr() << "The sample rate must be positive.\n" << usage << general_options);

  asp::stereo_settings().enable_correct_velocity_aberration
    = opt.enable_correct_velocity_aberration;
  asp::stereo_settings().enable_correct_atmospheric_refraction
    = opt.enable_correct_atmospheric_refraction;
  asp::stereo_settings().dg_use_csm = opt.dg_use_csm;

  // Need this to be able to load adjusted camera models. This must be set
  // before loading the cameras.
  asp::stereo_settings().bundle_adjust_prefix = opt.bundle_adjust_prefix;

  if (opt.test_error_propagation) {
    if (!asp::stereo_settings().dg_use_csm) {
      vw_out() << "Enabling option --dg-use-csm as point cloud stddev will be computed.\n";
      asp::stereo_settings().dg_use_csm = true;
    }
    asp::stereo_settings().propagate_errors = true;
  }
}

// Sort the diffs and print some stats
void print_diffs(std::string const& tag, std::vector<double> & diffs) {
  std::sort(diffs.begin(), diffs.end());

  vw_out() << "\n";

  if (diffs.empty()) {
    vw_out() << "Empty list of diffs for: " << tag << "\n";
    return;
  }

  vw_out() << tag << "\n";
  vw_out() << "Min:    " << diffs[0] << "\n";
  vw_out() << "Median: " << diffs[diffs.size()/2] << "\n";
  vw_out() << "Max:    " << diffs.back() << "\n";
}

void testErrorPropagation(Options const& opt,
                          vw::cartography::Datum const& datum,
                          vw::CamPtr cam1_model,
                          vw::CamPtr cam2_model) {

  double major_axis = datum.semi_major_axis() + opt.height_above_datum;
  double minor_axis = datum.semi_minor_axis() + opt.height_above_datum;

  // Try to find a pair of pixels corresponding to same tri point,
  // within image bounds
  vw::Vector2 pix1, pix2;
  Vector3 triPt;
  for (int i = 0; i < 20; i++) {

    pix1 = Vector2(i * 1000, i * 1000);
    Vector3 cam1_dir = cam1_model->pixel_to_vector(pix1);
    Vector3 cam1_ctr = cam1_model->camera_center(pix1);

    // Shoot a ray from the cam1 camera, intersect it with the
    // given height above datum
    triPt = vw::cartography::datum_intersection(major_axis, minor_axis,
                                                      cam1_ctr, cam1_dir);

    // Project to second camera
    pix2 = cam2_model->point_to_pixel(triPt);

    if (pix2.x() > 0 && pix2.y() > 0)
      break;
  }

  std::cout << "Left pixel:  " << pix1 << std::endl;
  std::cout << "Right pixel: " << pix2 << std::endl;

  vw::Vector2 ans = asp::propagateCovariance(triPt, datum,
                                             cam1_model.get(), cam2_model.get(),
                                             pix1, pix2);
  std::cout << "Horizontal and vertical stddev: " << ans << std::endl;
}

int main(int argc, char *argv[]) {

  Options opt;
  try {
    handle_arguments(argc, argv, opt);

    // Load cam1
    std::string out_prefix;
    std::string default_session1 = opt.session1; // save it before it changes
    SessionPtr cam1_session(asp::StereoSessionFactory::create
                               (opt.session1, // may change
                                opt,
                                opt.image_file, opt.image_file,
                                opt.cam1_file, opt.cam1_file,
                                out_prefix));
    boost::shared_ptr<vw::camera::CameraModel> cam1_model
      = cam1_session->camera_model(opt.image_file, opt.cam1_file);

    // Load cam2
    std::string default_session2 = opt.session2; // save it before it changes
    SessionPtr cam2_session(asp::StereoSessionFactory::create
                           (opt.session2, // may change
                            opt,
                            opt.image_file, opt.image_file,
                            opt.cam2_file, opt.cam2_file,
                            out_prefix));
    boost::shared_ptr<vw::camera::CameraModel> cam2_model
      = cam2_session->camera_model(opt.image_file, opt.cam2_file);

    vw::cartography::Datum datum;
    if (opt.datum == "") {
      // Auto-guess the datum, this is the default
      bool use_sphere_for_non_earth = true;
      datum = cam1_session->get_datum(cam1_model.get(), use_sphere_for_non_earth);

      // Sanity check
      vw::cartography::Datum datum2 = cam2_session->get_datum(cam2_model.get(), 
                                                              use_sphere_for_non_earth);
      if (datum.semi_major_axis() != datum2.semi_major_axis() ||
          datum.semi_minor_axis() != datum2.semi_minor_axis())
            vw::vw_out(vw::WarningMessage) << "The two cameras have different datums:\n" 
                                           << datum << "\n" << datum2 << "\n"
                                           << "Consider using the --datum option.\n";
    } else {
      // Use the datum specified by the user
      datum.set_well_known_datum(opt.datum);
    }
    vw_out() << "Using datum: " << datum << std::endl;

    // Sanity check
    if (norm_2(cam1_model->camera_center(Vector2())) < datum.semi_major_axis() ||
        norm_2(cam2_model->camera_center(Vector2())) < datum.semi_major_axis())   
            vw::vw_out(vw::WarningMessage) << "First or second camera center is below "
            << "the datum semi-major axis. Check your data. Consider using "
            << "the --datum and/or --height-above-datum options.\n"; 

    if (opt.session1 == opt.session2 && (default_session1 == "" || default_session2 == ""))
      vw_throw(ArgumentErr() << "The session names for both cameras "
               << "were guessed as: '" << opt.session1 << "'. It is suggested that they be "
               << "explicitly specified using --session1 and --session2.\n");

    if (opt.test_error_propagation && opt.session1 == "dg" && opt.session2 == "dg") {
      testErrorPropagation(opt, datum, cam1_model, cam2_model);
      return 0;
    }

    // Find the input image dimensions
    int image_cols = 0, image_rows = 0;
    try {
      DiskImageView<float> image(opt.image_file);
      image_cols = image.cols();
      image_rows = image.rows();
    } catch(const std::exception& e) {
      // For CSM-to-CSM ground-to-image and image-to-ground comparisons only,
      // the camera has the dimensions if the .cub image is missing.
      asp::CsmModel * csm_model
        = dynamic_cast<asp::CsmModel*>(vw::camera::unadjusted_model(cam1_model.get()));
      if (csm_model != NULL) {
        image_cols = csm_model->get_image_size()[0];
        image_rows = csm_model->get_image_size()[1];
      } else {
        vw::vw_throw(ArgumentErr() << e.what());
      }
    }

    vw_out() << "Image dimensions: " << image_cols << ' ' << image_rows << std::endl;

    bool single_pix = !std::isnan(opt.single_pixel[0]) && !std::isnan(opt.single_pixel[1]);

    Stopwatch sw;
    sw.start();

    double major_axis = datum.semi_major_axis() + opt.height_above_datum;
    double minor_axis = datum.semi_minor_axis() + opt.height_above_datum;
    // Iterate over the image
    std::vector<double> ctr_diff, dir_diff, cam1_to_cam2_diff, cam2_to_cam1_diff, dg_vs_csm_diff;
    for (int col = 0; col < image_cols; col += opt.sample_rate) {
      for (int row = 0; row < image_rows; row += opt.sample_rate) {

        Vector2 image_pix(col + opt.subpixel_offset, row + opt.subpixel_offset);

        if (single_pix)
          image_pix = opt.single_pixel;

        if (opt.print_per_pixel_results || single_pix)
          vw_out() << "Pixel: " << image_pix << "\n";

        Vector3 cam1_ctr = cam1_model->camera_center(image_pix);
        Vector3 cam2_ctr = cam2_model->camera_center(image_pix);
        ctr_diff.push_back(norm_2(cam1_ctr - cam2_ctr));

        if (opt.print_per_pixel_results)
          vw_out() << "Camera center diff: " << ctr_diff.back() << std::endl;

        Vector3 cam1_dir = cam1_model->pixel_to_vector(image_pix);
        Vector3 cam2_dir = cam2_model->pixel_to_vector(image_pix);
        dir_diff.push_back(norm_2(cam1_dir - cam2_dir));

        if (opt.print_per_pixel_results)
          vw_out() << "Camera direction diff: " << dir_diff.back() << std::endl;

        // Shoot a ray from the cam1 camera, intersect it with the
        // given height above datum, and project it back into the cam2
        // camera.
        Vector3 xyz = vw::cartography::datum_intersection(major_axis, minor_axis,
                                                          cam1_ctr, cam1_dir);

        Vector2 cam2_pix = cam2_model->point_to_pixel(xyz);
        cam1_to_cam2_diff.push_back(norm_2(image_pix - cam2_pix));

        if (opt.print_per_pixel_results)
          vw_out() << "cam1 to cam2 pixel diff: " << image_pix - cam2_pix << std::endl;

        if (opt.dg_vs_csm) {
          asp::stereo_settings().dg_use_csm = !asp::stereo_settings().dg_use_csm;
          Vector2 cam2_pix2 = cam2_model->point_to_pixel(xyz);
          asp::stereo_settings().dg_use_csm = !asp::stereo_settings().dg_use_csm;
          dg_vs_csm_diff.push_back(norm_2(cam2_pix - cam2_pix2));
        }

        // Shoot a ray from the cam2 camera, intersect it with the
        // given height above the datum, and project it back into the
        // cam1 camera.
        xyz = vw::cartography::datum_intersection(major_axis, minor_axis,
                                                  cam2_ctr, cam2_dir);
        Vector2 cam1_pix = cam1_model->point_to_pixel(xyz);
        cam2_to_cam1_diff.push_back(norm_2(image_pix - cam1_pix));

        if (opt.print_per_pixel_results)
          vw_out() << "cam2 to cam1 pixel diff: " << image_pix - cam1_pix << "\n\n";

        if (opt.dg_vs_csm) {
          asp::stereo_settings().dg_use_csm = !asp::stereo_settings().dg_use_csm;
          Vector2 cam1_pix2 = cam1_model->point_to_pixel(xyz);
          asp::stereo_settings().dg_use_csm = !asp::stereo_settings().dg_use_csm;
          dg_vs_csm_diff.push_back(norm_2(cam1_pix - cam1_pix2));
        }

        if (single_pix)
          break;
      }

      if (single_pix)
        break;
    }

    sw.stop();
    vw_out() << "Number of samples used: " << ctr_diff.size() << "\n";

    print_diffs("cam1 to cam2 camera direction diff norm", dir_diff);
    print_diffs("cam1 to cam2 camera center diff (meters)", ctr_diff);
    print_diffs("cam1 to cam2 pixel diff", cam1_to_cam2_diff);
    print_diffs("cam2 to cam1 pixel diff", cam2_to_cam1_diff);
    if (opt.dg_vs_csm)
    print_diffs("dg vs csm pixel diff", dg_vs_csm_diff);

    double elapsed_sec = sw.elapsed_seconds();
    vw_out() << "\nElapsed time per sample: " << 1e+6 * elapsed_sec/ctr_diff.size()
             << " milliseconds.\n";

    if (elapsed_sec < 5)
      vw_out() << "It is suggested to adjust the sample rate to produce more samples "
               << "if desired to evaluate more accurately the elapsed time per sample.\n";

  } ASP_STANDARD_CATCHES;

  return 0;
}
