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

/// \file bundle_adjust.cc

// TODO(oalexan1): Break this up into several files grouped by functionality.
// Also for bundle_adjust.h. See existing BundleAdjustCamera.cc and
// BundleAdjustUtils.cc.
#include <vw/Camera/CameraUtilities.h>
#include <vw/Core/CmdUtils.h>
#include <vw/FileIO/MatrixIO.h>
#include <asp/Core/Macros.h>
#include <asp/Sessions/StereoSession.h>
#include <asp/Sessions/StereoSessionFactory.h>
#include <asp/Sessions/CameraUtils.h>
#include <asp/Core/StereoSettings.h>
#include <asp/Core/PointUtils.h>
#include <asp/Core/IpMatchingAlgs.h> // Lightweight header for ip matching
#include <asp/Tools/bundle_adjust.h>
#include <asp/Camera/CsmModel.h>
#include <asp/Core/OutlierProcessing.h>
#include <asp/Core/DataLoader.h>

#include <vw/InterestPoint/Matcher.h>

#include <xercesc/util/PlatformUtils.hpp>

namespace po = boost::program_options;
namespace fs = boost::filesystem;

using namespace vw;
using namespace vw::camera;
using namespace vw::ba;

typedef boost::shared_ptr<asp::StereoSession> SessionPtr;
typedef CameraRelationNetwork<JFeature> CRNJ;

/// Write a csm camera state file to disk.
void write_csm_output_file(Options const& opt, int icam,
                           std::string const& adjustFile, 
                           asp::BAParams const& param_storage) {
  
  CameraAdjustment cam_adjust(param_storage.get_camera_ptr(icam));
  
  AdjustedCameraModel adj_cam(vw::camera::unadjusted_model(opt.camera_models[icam]),
                              cam_adjust.position(), cam_adjust.pose());
  
  vw::Matrix4x4 ecef_transform = adj_cam.ecef_transform();
  std::string csmFile          = asp::csmStateFile(adjustFile);
  asp::CsmModel * csm_model    = asp::csm_model(opt.camera_models[icam], opt.stereo_session);
  csm_model->saveTransformedState(csmFile, ecef_transform);
}

// Save pinhole camera positions and orientations in a single file.
// This is useful if there are thousands of cameras.
// TODO(oalexan1): Add here initial and final prefix.
// TODO(oalexan1): This must work only for pinhole.
void saveCameraReport(Options const& opt, asp::BAParams const& param_storage,
                      vw::cartography::Datum const& datum, 
                      std::string const& prefix) {

  std::string output_path = opt.out_prefix + "-" + prefix + "-cameras.csv";

  vw_out() << "Writing: " << output_path << std::endl;
  std::ofstream fh(output_path.c_str());
  fh.precision(17);
  fh << "# input_cam_file, cam_ctr_x, cam_ctr_y, cam_ctr_z (ecef meters), "
     << "cam2ned rotation rows\n";
  
  int num_cameras = opt.image_files.size();

  // TODO(oalexan1): Create here a report file. Write camera name,
  // camera center, ecef position, ecef quaternion, and ned roll-pitch-yaw.
  // Use same Euler angles as in numpy. Likely eigen can do it.
  for (int icam = 0; icam < num_cameras; icam++) {

    vw::Vector3 cam_ctr;
    vw::Matrix3x3 cam2ecef;
    switch(opt.camera_type) {
    case BaCameraType_Pinhole:
      {
        // Get the camera model from the original one with parameters in
        // param_storage applied to it (which could be original ones or optimized). 
        // Note that we do not modify the original camera.
        vw::camera::PinholeModel const* in_cam
          = dynamic_cast<vw::camera::PinholeModel const*>(opt.camera_models[icam].get());
        if (in_cam == NULL)
          vw_throw(ArgumentErr() << "Expecting a pinhole camera.\n");
        // Apply current intrinsics and extrinsics to the camera
        vw::camera::PinholeModel out_cam = transformedPinholeCamera(icam, param_storage, *in_cam);
        cam_ctr = out_cam.camera_center(vw::Vector2());
        cam2ecef = out_cam.get_rotation_matrix();
        break;
      }
    case BaCameraType_OpticalBar:
      vw::vw_throw(vw::ArgumentErr() << "Saving a camera report is not implemented "
                   << "for optical bar cameras.\n");
      break;
    default:
      {
        // Apply extrinsics adjustments to a pinhole camera
        // TODO(oalexan1): Make this into a function called adjustedPinholeCamera().
        // Use it where needed.
        CameraAdjustment adjustment(param_storage.get_camera_ptr(icam));
        PinholeModel* in_cam = dynamic_cast<PinholeModel*>(opt.camera_models[icam].get());
        if (in_cam == NULL)
          vw_throw(ArgumentErr() << "Expecting a pinhole camera.\n");
        
        // Make a copy of the camera, and apply the adjustments to the copy. Need to go back
        // to the original camera to get the adjustments needed to apply.
        // TODO(oalexan1): This is a little awkward.
        PinholeModel out_cam = *in_cam;
        AdjustedCameraModel adj_cam(vw::camera::unadjusted_model(opt.camera_models[icam]),
                                    adjustment.position(), adjustment.pose());
        vw::Matrix4x4 ecef_transform = adj_cam.ecef_transform();
        out_cam.apply_transform(ecef_transform);
        cam_ctr = out_cam.camera_center(vw::Vector2());
        cam2ecef = out_cam.get_rotation_matrix();
      }
    }

    fh << opt.camera_files[icam] << ", "
       << cam_ctr[0] << ", " << cam_ctr[1] << ", " << cam_ctr[2];

    // Find the matrix for converting NED to ECEF
    vw::Vector3 loc_llh = datum.cartesian_to_geodetic(cam_ctr);
    vw::Matrix3x3 ned2ecef = datum.lonlat_to_ned_matrix(subvector(loc_llh, 0, 2));

    // How a camera moves relative to the world is given by the camera-to-world
    // matrix. That is a little counter-intuitive.
    vw::Matrix3x3 cam2ned = inverse(ned2ecef) * cam2ecef;
    for (int row = 0; row < cam2ned.rows(); row++) {
      for (int col = 0; col < cam2ned.cols(); col++) {
        fh << ", " << cam2ned(row, col);
      } 
    }
    fh << "\n";
    // See
    // https://stackoverflow.com/questions/27508242/roll-pitch-and-yaw-from-rotation-matrix-with-eigen-library
    // for how to create roll-pitch-yaw. May need to first convert the
    // camera from NED to maybe East-South-Down, which may be
    // convenient if the camera flies North-to-South and the image
    // rows go West to East. In Eigen, the roll-pitch-yaw then could
    // be found as: m.eulerAngles(2,1,0)
  }

  fh.close();

  return;
}

// Write the results to disk.
void saveResults(Options const& opt, asp::BAParams const& param_storage) {
  int num_cameras = opt.image_files.size();

  for (int icam = 0; icam < num_cameras; icam++){

    switch(opt.camera_type) {
    case BaCameraType_Pinhole:
      write_pinhole_output_file(opt, icam, param_storage);
      break;
    case BaCameraType_OpticalBar:
      write_optical_bar_output_file(opt, icam, param_storage);
      break;
    default:
      std::string adjust_file = asp::bundle_adjust_file_name(opt.out_prefix,
                                                             opt.image_files[icam],
                                                             opt.camera_files[icam]);
      vw_out() << "Writing: " << adjust_file << std::endl;
      
      CameraAdjustment cam_adjust(param_storage.get_camera_ptr(icam));
      asp::write_adjustments(adjust_file, cam_adjust.position(), cam_adjust.pose());

      // For CSM camera models export, in addition, the JSON state
      // with the adjustment applied to it.
      if (opt.stereo_session == "csm" || opt.stereo_session == "pleiades" ||
          (opt.stereo_session == "dg" && asp::stereo_settings().dg_use_csm))
        write_csm_output_file(opt, icam, adjust_file, param_storage);
    }
    
  } // End loop through cameras
  
}

// A callback to invoke at each iteration if desiring to save the cameras
// at that time.
class BaCallback: public ceres::IterationCallback {
public:
  
  BaCallback(Options const& opt, asp::BAParams const& param_storage):
    m_opt(opt), m_param_storage(param_storage){}

  virtual ceres::CallbackReturnType operator() (const ceres::IterationSummary& summary) {
    saveResults(m_opt, m_param_storage);
    return ceres::SOLVER_CONTINUE;
  }
  
private:
  Options const& m_opt;
  asp::BAParams const& m_param_storage;
};

/// Add error source for projecting a 3D point into the camera.
void add_reprojection_residual_block(Vector2 const& observation, Vector2 const& pixel_sigma,
                                     int point_index, int camera_index, 
                                     asp::BAParams & param_storage,
                                     Options const& opt,
                                     ceres::Problem & problem){

  ceres::LossFunction* loss_function;
  loss_function = get_loss_function(opt);

  boost::shared_ptr<CameraModel> camera_model = opt.camera_models[camera_index];

  double* camera = param_storage.get_camera_ptr(camera_index);
  double* point  = param_storage.get_point_ptr (point_index );

  if (opt.camera_type == BaCameraType_Other) {
    // The generic camera case
    boost::shared_ptr<CeresBundleModelBase> wrapper(new AdjustedCameraBundleModel(camera_model));
      ceres::CostFunction* cost_function =
        BaReprojectionError::Create(observation, pixel_sigma, wrapper);
      problem.AddResidualBlock(cost_function, loss_function, point, camera);

  } else { // Pinhole and optical bar

    double* center     = param_storage.get_intrinsic_center_ptr    (camera_index);
    double* focus      = param_storage.get_intrinsic_focus_ptr     (camera_index);
    double* distortion = param_storage.get_intrinsic_distortion_ptr(camera_index);

    boost::shared_ptr<CeresBundleModelBase> wrapper;

    if (opt.camera_type == BaCameraType_Pinhole) {

      boost::shared_ptr<PinholeModel> pinhole_model = 
        boost::dynamic_pointer_cast<PinholeModel>(camera_model);
      if (pinhole_model.get() == 0)
        vw::vw_throw(vw::ArgumentErr() << "Tried to add pinhole block with non-pinhole camera.");
      wrapper.reset(new PinholeBundleModel(pinhole_model));

    } else { // Optical bar

      boost::shared_ptr<vw::camera::OpticalBarModel> bar_model = 
        boost::dynamic_pointer_cast<vw::camera::OpticalBarModel>(camera_model);
      if (bar_model.get() == 0)
        vw::vw_throw( vw::ArgumentErr() << "Tried to add optical bar block with "
                      << "non-optical bar camera.");
      wrapper.reset(new OpticalBarBundleModel(bar_model));
    }

    ceres::CostFunction* cost_function =
      BaReprojectionError::Create(observation, pixel_sigma, wrapper);
    problem.AddResidualBlock(cost_function, loss_function, point, camera, 
                            center, focus, distortion);

    // Apply the residual limits
    size_t num_limits = opt.intrinsics_limits.size() / 2;
    if ((num_limits > 0) && (num_limits > wrapper->num_intrinsic_params())) {
      vw::vw_throw( vw::ArgumentErr() << "Error: Too many intrinsic limits provided!"
        << " This model has " << wrapper->num_intrinsic_params() << " intrinsic parameters.");
    }
    size_t intrin_index = 0;
    if (num_limits > 0) { // Do focus first.
      problem.SetParameterLowerBound(focus, 0, opt.intrinsics_limits[0]);
      problem.SetParameterUpperBound(focus, 0, opt.intrinsics_limits[1]);
      ++intrin_index;
    }
    while ((intrin_index < 3) && (intrin_index < num_limits)) { // Next is the two center params
      problem.SetParameterLowerBound(center, intrin_index-1,
                                     opt.intrinsics_limits[2*intrin_index    ]);
      problem.SetParameterUpperBound(center, intrin_index-1,
                                     opt.intrinsics_limits[2*intrin_index + 1]);
      ++intrin_index;
    }
    while (intrin_index < num_limits) { // Finish with the intrinsic params
      problem.SetParameterLowerBound(distortion, intrin_index-3,
                                     opt.intrinsics_limits[2*intrin_index    ]);
      problem.SetParameterUpperBound(distortion, intrin_index-3,
                                     opt.intrinsics_limits[2*intrin_index + 1]);
      ++intrin_index;
    }

    // If we don't want to solve for something, just tell Ceres not to adjust the values.
    if (opt.intrinisc_options.center_constant)
      problem.SetParameterBlockConstant(center);
    if (opt.intrinisc_options.focus_constant)
      problem.SetParameterBlockConstant(focus);
    if (opt.intrinisc_options.distortion_constant)
      problem.SetParameterBlockConstant(distortion);
  } // End non-generic camera case.

  // Fix this camera if requested
  if (opt.fixed_cameras_indices.find(camera_index) != opt.fixed_cameras_indices.end()) 
    problem.SetParameterBlockConstant(param_storage.get_camera_ptr(camera_index));
}

/// Add residual block for the error using reference xyz.
void add_disparity_residual_block(Vector3 const& reference_xyz,
                                  ImageViewRef<DispPixelT> const& interp_disp, 
                                  int left_cam_index, int right_cam_index,
                                  asp::BAParams & param_storage,
                                  Options const& opt,
                                  ceres::Problem & problem){

  ceres::LossFunction* loss_function = get_loss_function(opt);

  boost::shared_ptr<CameraModel> left_camera_model  = opt.camera_models[left_cam_index ];
  boost::shared_ptr<CameraModel> right_camera_model = opt.camera_models[right_cam_index];

  const bool inline_adjustments = (opt.camera_type != BaCameraType_Other);

  // Get the list of residual pointers that will be passed to ceres.
  std::vector<double*> residual_ptrs;
  BaDispXyzError::get_residual_pointers(param_storage,
                                        left_cam_index, right_cam_index,
                                        inline_adjustments, opt.intrinisc_options,
                                        residual_ptrs);
 if (opt.camera_type == BaCameraType_Other) {

    boost::shared_ptr<CeresBundleModelBase> left_wrapper (new AdjustedCameraBundleModel(left_camera_model ));
    boost::shared_ptr<CeresBundleModelBase> right_wrapper(new AdjustedCameraBundleModel(right_camera_model));
    ceres::CostFunction* cost_function =
      BaDispXyzError::Create(reference_xyz, interp_disp, left_wrapper, right_wrapper,
                             inline_adjustments, opt.intrinisc_options);

    problem.AddResidualBlock(cost_function, loss_function, residual_ptrs);

  } else { // Pinhole or optical bar

    boost::shared_ptr<CeresBundleModelBase> left_wrapper, right_wrapper;

    if (opt.camera_type == BaCameraType_Pinhole) {
      boost::shared_ptr<PinholeModel> left_pinhole_model = 
        boost::dynamic_pointer_cast<vw::camera::PinholeModel>(left_camera_model);
      boost::shared_ptr<PinholeModel> right_pinhole_model = 
        boost::dynamic_pointer_cast<vw::camera::PinholeModel>(right_camera_model);

      left_wrapper.reset (new PinholeBundleModel(left_pinhole_model ));
      right_wrapper.reset(new PinholeBundleModel(right_pinhole_model));

    } else { // Optical bar
      boost::shared_ptr<vw::camera::OpticalBarModel> left_bar_model = 
        boost::dynamic_pointer_cast<vw::camera::OpticalBarModel>(left_camera_model);
      boost::shared_ptr<vw::camera::OpticalBarModel> right_bar_model = 
        boost::dynamic_pointer_cast<vw::camera::OpticalBarModel>(right_camera_model);

      left_wrapper.reset (new OpticalBarBundleModel(left_bar_model ));
      right_wrapper.reset(new OpticalBarBundleModel(right_bar_model));
    }

    ceres::CostFunction* cost_function =
      BaDispXyzError::Create(reference_xyz, interp_disp, left_wrapper, right_wrapper,
                             inline_adjustments, opt.intrinisc_options);
    problem.AddResidualBlock(cost_function, loss_function, residual_ptrs);

  }
  
} // End function add_disparity_residual_block


//----------------------------------------------------------------
// Residuals functions

/// Compute the residuals
void compute_residuals(bool apply_loss_function,
                       Options const& opt,
                       asp::BAParams const& param_storage,
                       std::vector<size_t> const& cam_residual_counts,
                       size_t num_gcp_or_dem_residuals,
                       size_t num_tri_residuals,
                       std::vector<vw::Vector3> const& reference_vec,
                       ceres::Problem & problem,
                       // Output
                       std::vector<double> & residuals) {
  // TODO: Associate residuals with cameras!
  // Generate some additional diagnostic info
  double cost = 0.0;
  ceres::Problem::EvaluateOptions eval_options;
  eval_options.apply_loss_function = apply_loss_function;
  if (opt.single_threaded_cameras)
    eval_options.num_threads = 1; // ISIS must be single threaded!
  else
    eval_options.num_threads = opt.num_threads;

  problem.Evaluate(eval_options, &cost, &residuals, 0, 0);
  const size_t num_residuals = residuals.size();
  
  // Verify our book-keeping is correct
  size_t num_expected_residuals
    = (num_gcp_or_dem_residuals + num_tri_residuals) * param_storage.params_per_point();
  size_t total_num_cam_params   = param_storage.num_cameras()*param_storage.params_per_camera();
  for (size_t i=0; i<param_storage.num_cameras(); i++)
    num_expected_residuals += cam_residual_counts[i]*PIXEL_SIZE;
  if (opt.camera_weight > 0)
    num_expected_residuals += total_num_cam_params;
  if (opt.rotation_weight > 0 || opt.translation_weight > 0)
    num_expected_residuals += total_num_cam_params;
  num_expected_residuals += reference_vec.size() * PIXEL_SIZE;
  
  if (num_expected_residuals != num_residuals)
    vw_throw( LogicErr() << "Expected " << num_expected_residuals
                         << " residuals but instead got " << num_residuals);
}

/// Compute residual map by averaging all the reprojection error at a given point
void compute_mean_residuals_at_xyz(CRNJ & crn,
                                  std::vector<double> const& residuals,
                                  asp::BAParams const& param_storage,
                                  // outputs
                                  std::vector<double> & mean_residuals,
                                  std::vector<int>  & num_point_observations) {

  mean_residuals.resize(param_storage.num_points());
  num_point_observations.resize(param_storage.num_points());
  
  // Observation residuals are stored at the beginning of the residual vector in the 
  //  same order they were originally added to Ceres.
  
  size_t residual_index = 0;
  // Double loop through cameras and crn entries will give us the correct order
  for ( size_t icam = 0; icam < param_storage.num_cameras(); icam++ ) {
    typedef CameraNode<JFeature>::const_iterator crn_iter;
    for (crn_iter fiter = crn[icam].begin(); fiter != crn[icam].end(); fiter++){

      // The index of the 3D point
      int ipt = (**fiter).m_point_id;

      if (param_storage.get_point_outlier(ipt))
        continue; // skip outliers

      // Get the residual error for this observation
      double errorX         = residuals[residual_index  ];
      double errorY         = residuals[residual_index+1];
      // TODO(oalexan1): Use norm_2 below rather than average. This may
      // change the regressions.
      double residual_error = (fabs(errorX) + fabs(errorY)) / 2;
      residual_index += PIXEL_SIZE;

      // Update information for this point
      num_point_observations[ipt] += 1;
      mean_residuals        [ipt] += residual_error;
    }
  } // End double loop through all the observations

  // Do the averaging
  for (size_t i = 0; i < param_storage.num_points(); i++) {
    if (param_storage.get_point_outlier(i)) {
      // Skip outliers. But initialize to something.
      mean_residuals        [i] = std::numeric_limits<double>::quiet_NaN();
      num_point_observations[i] = std::numeric_limits<int>::quiet_NaN();
      continue;
    }
    mean_residuals[i] /= static_cast<double>(num_point_observations[i]);
  }
  
} // End function compute_mean_residuals_at_xyz

/// Write out a .csv file recording the residual error at each location on the ground
void write_residual_map(std::string const& output_prefix,
                        // Mean residual of each point
                        std::vector<double> const& mean_residuals,
                        // Num non-outlier pixels per point
                        std::vector<int> const& num_point_observations, 
                        asp::BAParams const& param_storage,
                        ControlNetwork const& cnet,
                        Options const& opt) {

  std::string output_path = output_prefix + ".csv";

  if (opt.datum.name() == asp::UNSPECIFIED_DATUM) {
    vw_out(WarningMessage) << "No datum specified, can't write file: " << output_path << ". "
                           << "With Earth satellite images add the option '-t nadirpinhole' "
                           << "to use the WGS84 datum, or else specify '--datum <planet name>'.\n";
    return;
  }
  if (mean_residuals.size() != param_storage.num_points())
    vw_throw( LogicErr() << "Point count mismatch in write_residual_map().\n");

  if (cnet.size() != param_storage.num_points()) 
    vw_throw( LogicErr()
              << "The number of stored points "
              << "does not agree with number of points in cnet.\n");
  
  // Open the output file and write the header
  vw_out() << "Writing: " << output_path << std::endl;
  std::ofstream file;
  file.open(output_path.c_str());
  file.precision(17);
  file << "# lon, lat, height_above_datum, mean_residual, num_observations\n";

  // stereo_gui counts on being able to parse the datum from this file, so
  // do not modify the line below.
  file << "# " << opt.datum << std::endl;
  
  // Now write all the points to the file
  for (size_t i = 0; i < param_storage.num_points(); i++) {

    if (param_storage.get_point_outlier(i))
      continue; // skip outliers
    
      // The final GCC coordinate of this point
      const double * point = param_storage.get_point_ptr(i);
      Vector3 xyz(point[0], point[1], point[2]);

      Vector3 llh = opt.datum.cartesian_to_geodetic(xyz);

      std::string comment = "";
      if (cnet[i].type() == ControlPoint::GroundControlPoint)
        comment = " # GCP";
      else if (cnet[i].type() == ControlPoint::PointFromDem)
        comment = " # from DEM";
      
      file << llh[0] <<", "<< llh[1] <<", "<< llh[2] <<", "<< mean_residuals[i] <<", "
           << num_point_observations[i] << comment << std::endl;
  }
  file.close();

} // End function write_residual_map


/// Write log files describing all residual errors. The order of data stored
/// in residuals must mirror perfectly the way residuals were created. 
void write_residual_logs(std::string const& residual_prefix, bool apply_loss_function,
                         Options const& opt,
                         asp::BAParams const& param_storage,
                         std::vector<size_t> const& cam_residual_counts,
                         size_t num_gcp_or_dem_residuals,
                         size_t num_tri_residuals,
                         std::vector<vw::Vector3> const& reference_vec,
                         ControlNetwork const& cnet, CRNJ & crn, 
                         ceres::Problem &problem) {
  
  std::vector<double> residuals;
  compute_residuals(apply_loss_function, opt, param_storage,
                    cam_residual_counts, num_gcp_or_dem_residuals, num_tri_residuals,
                    reference_vec, problem,
                    // Output
                    residuals);
    
  const size_t num_residuals = residuals.size();

  const std::string residual_path               = residual_prefix + "_stats.txt";
  const std::string residual_raw_pixels_path    = residual_prefix + "_raw_pixels.txt";
  const std::string residual_raw_gcp_path       = residual_prefix + "_raw_gcp.txt";
  const std::string residual_raw_cams_path      = residual_prefix + "_raw_cameras.txt";
  const std::string residual_reference_xyz_path = residual_prefix + "_reference_terrain.txt";

  // Write a report on residual errors
  std::ofstream residual_file, residual_file_raw_pixels, residual_file_raw_gcp,
    residual_file_raw_cams, residual_file_reference_xyz;
  vw_out() << "Writing: " << residual_path << std::endl;
  vw_out() << "Writing: " << residual_raw_pixels_path << std::endl;
  vw_out() << "Writing: " << residual_raw_gcp_path << std::endl;
  vw_out() << "Writing: " << residual_raw_cams_path << std::endl;
  
  residual_file.open(residual_path.c_str());
  residual_file.precision(17);
  residual_file_raw_pixels.open(residual_raw_pixels_path.c_str());
  residual_file_raw_pixels.precision(17);
  residual_file_raw_cams.open(residual_raw_cams_path.c_str());
  residual_file_raw_cams.precision(17);

  if (reference_vec.size() > 0) {
    //vw_out() << "Writing: " << residual_reference_xyz_path << std::endl;
    residual_file_reference_xyz.open(residual_reference_xyz_path.c_str());
    residual_file_reference_xyz.precision(17);
  }
  
  size_t index = 0;
  // For each camera, average together all the point observation residuals
  residual_file << "Mean and median norm of residual error and point count for cameras:\n";
  for (size_t c = 0; c < param_storage.num_cameras(); c++) {
    size_t num_this_cam_residuals = cam_residual_counts[c];
    
    // Write header for the raw file
    std::string name = opt.camera_files[c];
    if (name == "")
      name = opt.image_files[c];
    
    residual_file_raw_pixels << name << ", " << num_this_cam_residuals << std::endl;

    // All residuals are for inliers, as we do not even add a residual
    // for an outlier
    
    double mean_residual = 0; // Take average of all pixel coord errors
    std::vector<double> residual_norms;
    for (size_t i = 0; i < num_this_cam_residuals; i++) {
      double ex = residuals[index];
      ++index;
      double ey = residuals[index];
      ++index;
      double residual_norm = std::sqrt(ex * ex + ey * ey);
      mean_residual += residual_norm;
      residual_norms.push_back(residual_norm);
      residual_file_raw_pixels << ex << ", " << ey << std::endl; // Write ex, ey on raw file
    }
    // Write line for the summary file
    mean_residual /= static_cast<double>(num_this_cam_residuals);
    double median_residual = std::numeric_limits<double>::quiet_NaN();
    if (residual_norms.size() > 0) {
      std::sort(residual_norms.begin(), residual_norms.end());
      median_residual = residual_norms[residual_norms.size()/2];
    }
    
    residual_file << name                   << ", "
                  << mean_residual          << ", "
                  << median_residual        << ", "
                  << num_this_cam_residuals << std::endl;
  }
  
  residual_file_raw_pixels.close();
  
  // List the GCP residuals
  if (num_gcp_or_dem_residuals > 0) {
    residual_file_raw_gcp.open(residual_raw_gcp_path.c_str());
    residual_file_raw_gcp.precision(17);
    residual_file << "GCP or DEM residual errors:\n";
    for (size_t i = 0; i < num_gcp_or_dem_residuals; i++) {
      double mean_residual = 0; // Take average of XYZ error for each point
      residual_file_raw_gcp << i;
      for (size_t j = 0; j < param_storage.params_per_point(); j++) {
        mean_residual += fabs(residuals[index]);
        residual_file_raw_gcp << ", " << residuals[index]; // Write all values in this file
        ++index;
      }
      mean_residual /= static_cast<double>(param_storage.params_per_point());
      residual_file << i << ", " << mean_residual << std::endl;
      residual_file_raw_gcp << std::endl;
    }
    residual_file_raw_gcp.close();
  }
  
  // List the camera weight residuals
  int num_passes = int(opt.camera_weight > 0) +
    int(opt.rotation_weight > 0 || opt.translation_weight > 0);
  for (int pass = 0; pass < num_passes; pass++) {
    residual_file << "Camera weight position and orientation residual errors:\n";
    const size_t part_size = param_storage.params_per_camera()/2;
    for (size_t c=0; c<param_storage.num_cameras(); ++c) {
      residual_file_raw_cams << opt.camera_files[c];
      // Separately compute the mean position and rotation error
      double mean_residual_pos = 0, mean_residual_rot = 0;
      for (size_t j = 0; j < part_size; j++) {
        mean_residual_pos += fabs(residuals[index]);
        residual_file_raw_cams << ", " << residuals[index]; // Write all values in this file
        ++index;
      }
      for (size_t j = 0; j < part_size; j++) {
        mean_residual_rot += fabs(residuals[index]);
        residual_file_raw_cams << ", " << residuals[index]; // Write all values in this file
        ++index;
      }
      mean_residual_pos /= static_cast<double>(part_size);
      mean_residual_rot /= static_cast<double>(part_size);
    
      residual_file << opt.camera_files[c] << ", " << mean_residual_pos << ", "
                    << mean_residual_rot << std::endl;
      residual_file_raw_cams << std::endl;
    }
  }
  residual_file_raw_cams.close();
  residual_file.close();

  // List residuals for matching input terrain (lidar)
  if (reference_vec.size() > 0) {
    residual_file << "reference terrain residual errors:\n";
    residual_file_reference_xyz << "# lon, lat, height_above_datum, pixel_error_norm\n";
    for (size_t i = 0; i < reference_vec.size(); i++) {

      Vector3 llh = opt.datum.cartesian_to_geodetic(reference_vec[i]);
      double err = norm_2(Vector2(residuals[index], residuals[index + 1]));

      // Divide back the residual by the multiplier weight
      if (opt.reference_terrain_weight > 0) 
        err /= opt.reference_terrain_weight;
      
      index += PIXEL_SIZE;
      residual_file_reference_xyz << llh[0] << ", " << llh[1] << ", " << llh[2] << ", "
                                  << err << "\n";
      residual_file << i << ", " << err << "\n";
      
    }
    residual_file_reference_xyz.close();
  }

  // Keep track of number of triangulation constraint residuals but don't save those
  index += asp::BAParams::PARAMS_PER_POINT * num_tri_residuals;
  
  if (index != num_residuals)
    vw_throw( LogicErr() << "Have " << num_residuals << " residuals, but iterated through "
              << index);

  // Generate the location based file
  std::string map_prefix = residual_prefix + "_pointmap";
  std::vector<double> mean_residuals;
  std::vector<int> num_point_observations;
  compute_mean_residuals_at_xyz(crn,  residuals,  param_storage,
                                mean_residuals, num_point_observations);

  write_residual_map(map_prefix, mean_residuals, num_point_observations,
                     param_storage, cnet, opt);

} // End function write_residual_logs


// End residual functions
// ----------------------------------------------------------------

// ----------------------------------------------------------------
// Start outlier functions

/// Add to the outliers based on the large residuals
int add_to_outliers(ControlNetwork & cnet,
                    CRNJ & crn,
                    asp::BAParams & param_storage,
                    Options const& opt,
                    std::vector<size_t> const& cam_residual_counts,
                    size_t num_gcp_or_dem_residuals,
                    size_t num_tri_residuals,
                    std::vector<vw::Vector3> const& reference_vec, 
                    ceres::Problem &problem) {

  vw_out() << "Removing pixel outliers in preparation for another solver attempt.\n";

  const size_t num_points  = param_storage.num_points();
  const size_t num_cameras = param_storage.num_cameras();
  
  // Compute the reprojection error. Hence we should not add the contribution
  // of the loss function.
  bool apply_loss_function = false;
  std::vector<double> residuals;
  compute_residuals(apply_loss_function,  
                    opt, param_storage,  cam_residual_counts,  
                    num_gcp_or_dem_residuals, num_tri_residuals, reference_vec, problem,
                    // output
                    residuals);

  // Compute the mean residual at each xyz, and how many times that residual is seen
  std::vector<double> mean_residuals;
  std::vector<int   > num_point_observations;
  compute_mean_residuals_at_xyz(crn,  residuals,  param_storage,
                                // outputs
                                mean_residuals, num_point_observations);

  // The number of mean residuals is the same as the number of points,
  // of which some are outliers. Hence need to collect only the
  // non-outliers so far to be able to remove new outliers.  Need to
  // follow the same logic as when residuals were formed. And also ignore GCP.
  std::vector<double> actual_residuals;
  std::set<int> was_added;
  for ( size_t icam = 0; icam < num_cameras; icam++ ) {
    typedef CameraNode<JFeature>::const_iterator crn_iter;
    for ( crn_iter fiter = crn[icam].begin(); fiter != crn[icam].end(); fiter++ ){

      // The index of the 3D point
      int ipt = (**fiter).m_point_id;

      // skip existing outliers
      if (param_storage.get_point_outlier(ipt))
        continue; 

      // Skip gcp, those are never outliers no matter what.
      if (cnet[ipt].type() == ControlPoint::GroundControlPoint)
        continue;

      // We already encountered this residual in the previous camera
      if (was_added.find(ipt) != was_added.end()) 
        continue;
      
      was_added.insert(ipt);
      actual_residuals.push_back(mean_residuals[ipt]);
      //vw_out() << "XYZ residual " << ipt << " = " << mean_residuals[ipt] << std::endl;
    }
  } // End double loop through all the observations

  double pct      = 1.0 - opt.remove_outliers_params[0]/100.0;
  double factor   = opt.remove_outliers_params[1];
  double max_pix1 = opt.remove_outliers_params[2];
  double max_pix2 = opt.remove_outliers_params[3];

  double b, e; 
  vw::math::find_outlier_brackets(actual_residuals, pct, factor, b, e);
  vw_out() << "Outlier statistics: b = " << b << ", e = " << e << ".\n";
  
  // If this is too aggressive, the user can tame it. It is
  // unreasonable to throw out pixel residuals as small as 1 or 2
  // pixels.  We will not use the b, because the residuals start at 0.
  // - "max_pix" sets the minimum error that can be thrown out.
  e = std::min(std::max(e, max_pix1), max_pix2);

  vw_out() << "Removing as outliers points with mean reprojection error > " << e << ".\n";
  
  // Add to the outliers by reprojection error. Must repeat the same logic as above.
  // TODO(oalexan1): This removes a 3D point altogether if any reprojection
  // errors for it are big. Need to only remove bad reprojection errors
  // and keep a 3D point if it is left with at least two reprojection residuals.
  int num_outliers_by_reprojection = 0, total = 0;
  for ( size_t icam = 0; icam < num_cameras; icam++ ) {
    typedef CameraNode<JFeature>::const_iterator crn_iter;
    for ( crn_iter fiter = crn[icam].begin(); fiter != crn[icam].end(); fiter++ ){

      // The index of the 3D point
      int ipt = (**fiter).m_point_id;

      total++;
      
      // skip existing outliers
      if (param_storage.get_point_outlier(ipt))
        continue; 

      // Skip gcp
      if (cnet[ipt].type() == ControlPoint::GroundControlPoint)
        continue;

      if (mean_residuals[ipt] > e) {
        param_storage.set_point_outlier(ipt, true);
        num_outliers_by_reprojection++;
      }
    }
  } // End double loop through all the observations
  vw_out() << "Removed " << num_outliers_by_reprojection << " outliers out of "
           << total << " by reprojection error. Ratio: "
           << double(num_outliers_by_reprojection) / double(total) <<".\n";
  
  // Remove outliers by elevation limit
  int num_outliers_by_elev_or_lonlat = 0;
  if (opt.elevation_limit[0] < opt.elevation_limit[1] || !opt.lon_lat_limit.empty()) {

    for (size_t ipt = 0; ipt < param_storage.num_points(); ipt++) {

      if (cnet[ipt].type() == ControlPoint::GroundControlPoint)
        continue; // don't filter out GCP
      if (param_storage.get_point_outlier(ipt))
        continue; // skip outliers
      
      // The GCC coordinate of this point
      const double * point = param_storage.get_point_ptr(ipt);
      Vector3 xyz(point[0], point[1], point[2]);
      Vector3 llh = opt.datum.cartesian_to_geodetic(xyz);
      if (opt.elevation_limit[0] < opt.elevation_limit[1] && 
          (llh[2] < opt.elevation_limit[0] ||
           llh[2] > opt.elevation_limit[1])) {
        param_storage.set_point_outlier(ipt, true);
        num_outliers_by_elev_or_lonlat++;
        continue;
      }
      
      Vector2 lon_lat = subvector(llh, 0, 2);
      if ( !opt.lon_lat_limit.empty() && !opt.lon_lat_limit.contains(lon_lat) ) {
        param_storage.set_point_outlier(ipt, true);
        num_outliers_by_elev_or_lonlat++;
        continue;
      }
      
    }
    vw_out() << "Removed " << num_outliers_by_elev_or_lonlat
             << " outliers by elevation range and/or lon-lat range.\n";
  }

  // Remove outliers based on spatial extent. Be more generous with
  // leaving data in than what the input parameters suggest, because
  // sometimes inliers in space need not be uniformly distributed.
  double pct_factor = (3.0 + opt.remove_outliers_params[0]/100.0)/4.0; // e.g., 0.9375
  double outlier_factor = 2 * opt.remove_outliers_params[1];           // e.g., 6.0.
  std::vector<double> x_vals, y_vals, z_vals;
  for (size_t ipt = 0; ipt < param_storage.num_points(); ipt++) {
    
    if (cnet[ipt].type() == ControlPoint::GroundControlPoint)
      continue; // don't filter out GCP
    if (param_storage.get_point_outlier(ipt))
      continue; // skip outliers
    
    // The GCC coordinate of this point
    const double * point = param_storage.get_point_ptr(ipt);
    x_vals.push_back(point[0]);
    y_vals.push_back(point[1]);
    z_vals.push_back(point[2]);
  }
  vw::BBox3 estim_bdbox;
  asp::estimate_inliers_bbox(pct_factor, pct_factor, pct_factor,
                             outlier_factor,
                             x_vals, y_vals, z_vals,  
                             estim_bdbox); // output
  
  int num_box_outliers = 0;
  for (size_t ipt = 0; ipt < param_storage.num_points(); ipt++) {
    
    if (cnet[ipt].type() == ControlPoint::GroundControlPoint)
      continue; // don't filter out GCP
    if (param_storage.get_point_outlier(ipt))
      continue; // skip outliers
    
    // The GCC coordinate of this point
    const double * point = param_storage.get_point_ptr(ipt);
    Vector3 xyz(point[0], point[1], point[2]);
    if (!estim_bdbox.contains(xyz)) {
      param_storage.set_point_outlier(ipt, true);
      num_box_outliers++;
    }
  }

  vw_out() << "Removed " << num_box_outliers << " " 
           << "outlier(s) based on spatial distribution of triangulated points.\n";
  
  int num_remaining_points = num_points - param_storage.get_num_outliers();

  return num_outliers_by_reprojection + num_outliers_by_elev_or_lonlat;
}

// Find the cameras with the latest adjustments. Note that we do not modify
// opt.camera_models, but make copies as needed.
void calcOptimizedCameras(Options const& opt,
                          asp::BAParams const& param_storage,
                          std::vector<vw::CamPtr> & optimized_cams) {

  optimized_cams.clear();
  
  int num_cameras = opt.image_files.size();
  for (int icam = 0; icam < num_cameras; icam++) {
    
    // TODO(oalexan1): The logic below may need to be a function and should be called
    // in a couple other places.
    switch (opt.camera_type) {
    case BaCameraType_Pinhole:
      {
        vw::camera::PinholeModel const* in_cam
          = dynamic_cast<vw::camera::PinholeModel const*>(opt.camera_models[icam].get());
        if (in_cam == NULL)
          vw_throw(ArgumentErr() << "Expecting a pinhole camera.\n");
        vw::camera::PinholeModel * out_cam = new PinholeModel();
        *out_cam = transformedPinholeCamera(icam, param_storage, *in_cam);
        optimized_cams.push_back(vw::CamPtr(out_cam));
      }
      break;
      
    case BaCameraType_OpticalBar:
      {
        vw::camera::OpticalBarModel const* in_cam
          = dynamic_cast<vw::camera::OpticalBarModel const*>(opt.camera_models[icam].get());
        if (in_cam == NULL)
          vw_throw(ArgumentErr() << "Expecting an optical bar camera.\n");
        vw::camera::OpticalBarModel * out_cam = new OpticalBarModel();
        *out_cam = transformedOpticalBarCamera(icam, param_storage, *in_cam);
        optimized_cams.push_back(vw::CamPtr(out_cam));
      }
      break;
      
    default:
      {
        CameraAdjustment cam_adjust(param_storage.get_camera_ptr(icam));
        vw::CamPtr out_cam
          (new AdjustedCameraModel(vw::camera::unadjusted_model(opt.camera_models[icam]),
                                          cam_adjust.position(), cam_adjust.pose()));
        optimized_cams.push_back(out_cam);
      }
    }
  }
}

// End outlier functions
// ----------------------------------------------------------------
// TODO(oalexan1): Use this in jitter_solve.
// TODO(oalexan1): This needs to be done before subsampling the matches
void initial_filter_by_proj_win(Options             & opt,
                                asp::BAParams      & param_storage, 
                                ControlNetwork const& cnet) {

  // Swap y. Sometimes it is convenient to specify these on input in reverse.
  if (opt.proj_win.min().y() > opt.proj_win.max().y())
    std::swap(opt.proj_win.min().y(), opt.proj_win.max().y());

  // Set the projection. The function set_proj4_projection_str() does not set the
  // datum radii, which is confusing. Use asp::set_srs_string().
  vw::cartography::GeoReference georef;
  bool have_datum = (opt.datum.name() != asp::UNSPECIFIED_DATUM);
  bool have_input_georef = false;
  asp::set_srs_string(opt.proj_str, have_datum, opt.datum,
                      have_input_georef, georef);

  int num_points  = param_storage.num_points();
  for (int i = 0; i < num_points; i++) {
      
    if (param_storage.get_point_outlier(i))
      continue;
      
    double* point = param_storage.get_point_ptr(i);
    Vector3 xyz(point[0], point[1], point[2]);
    Vector3 llh = georef.datum().cartesian_to_geodetic(xyz);
    Vector2 proj_pt = georef.lonlat_to_point(subvector(llh, 0, 2));

    if (!opt.proj_win.contains(proj_pt))
      param_storage.set_point_outlier(i, true);
  }
}

int do_ba_ceres_one_pass(Options             & opt,
                         CRNJ                & crn,
                         bool                  first_pass,
                         asp::BAParams       & param_storage, 
                         asp::BAParams const & orig_parameters,
                         bool                & convergence_reached,
                         double              & final_cost) {

  ceres::Problem problem;

  ControlNetwork & cnet = *opt.cnet;
  const int num_cameras = param_storage.num_cameras();
  const int num_points  = param_storage.num_points();

  if ((int)crn.size() != num_cameras) 
    vw_throw(ArgumentErr() << "Book-keeping error, the size of CameraRelationNetwork "
             << "must equal the number of images.\n");
 
  convergence_reached = true;

  if (opt.proj_win != BBox2(0, 0, 0, 0) && (!opt.proj_str.empty()))
    initial_filter_by_proj_win(opt, param_storage, cnet);
  
  // How many times an xyz point shows up in the problem
  std::vector<int> count_map(num_points);
  for (int i = 0; i < num_points; i++) {
    if (param_storage.get_point_outlier(i))
      count_map[i] = 0; // skip outliers
    else
      count_map[i] = cnet[i].size(); // Get number of observations of this point.
  }

  // We will optimize multipliers of the intrinsics. This way
  // each intrinsic changes by a scale specific to it.
  // Note: If an intrinsic starts as 0, it will then stay as 0. This is documented.
  // Can be both useful and confusing.

  bool have_dem = (!opt.heights_from_dem.empty() || !opt.ref_dem.empty());
  
  // Create anchor xyz with the help of a DEM in two ways.
  // TODO(oalexan1): Study how to best pass the DEM to avoid the code
  // below not being slow. It is not clear if the DEM tiles are cached
  // when passing around an ImageViewRef.
  std::vector<Vector3> dem_xyz_vec;
  vw::cartography::GeoReference dem_georef;
  ImageViewRef<PixelMask<double>> interp_dem;
  std::set<int> outliers;
  if (have_dem) {
    for (int ipt = 0; ipt < num_points; ipt++) {
      if (param_storage.get_point_outlier(ipt))
        outliers.insert(ipt);
    }
  }
  if (opt.heights_from_dem != "") {
    asp::create_interp_dem(opt.heights_from_dem, dem_georef, interp_dem);
    asp::update_point_height_from_dem(cnet, outliers, dem_georef, interp_dem,  
                                      // Output
                                      dem_xyz_vec);
  }
  if (opt.ref_dem != "") {
    asp::create_interp_dem(opt.ref_dem, dem_georef, interp_dem);
    asp::calc_avg_intersection_with_dem(cnet, crn, outliers, opt.camera_models,
                                        dem_georef, interp_dem,
                                        // Output
                                        dem_xyz_vec);
  }
  
  // Add the cost function component for difference of pixel observations
  // - Reduce error by making pixel projection consistent with observations.
  
  // Add the various cost functions the solver will optimize over.
  std::vector<size_t> cam_residual_counts(num_cameras);
  typedef CameraNode<JFeature>::iterator crn_iter;
  for (int icam = 0; icam < num_cameras; icam++) { // Camera loop
    cam_residual_counts[icam] = 0;
    for (crn_iter fiter = crn[icam].begin(); fiter != crn[icam].end(); fiter++) { // IP loop

      // The index of the 3D point this IP is for.
      int ipt = (**fiter).m_point_id;
      if (param_storage.get_point_outlier(ipt))
        continue; // skip outliers

      VW_ASSERT(int(icam) < num_cameras,
                ArgumentErr() << "Out of bounds in the number of cameras.");
      VW_ASSERT(int(ipt)  < num_points,
                ArgumentErr() << "Out of bounds in the number of points.");

      double* point = param_storage.get_point_ptr(ipt);
      if (point[0] == 0 && point[1] == 0 && point[2] == 0) {
        // Flag points in the center of the planet as outliers
        param_storage.set_point_outlier(ipt, true);
        continue;
      }
      
      // Adjust non-GCP triangulated points based on the DEM, if
      // provided (two approaches are supported).
      bool is_gcp = (cnet[ipt].type() == ControlPoint::GroundControlPoint);
      if (have_dem && !is_gcp && dem_xyz_vec.at(ipt) != Vector3(0, 0, 0)) {
        for (int p = 0; p < 3; p++) 
          point[p] = dem_xyz_vec.at(ipt)[p]; // update the tri point based on the DEM
        cnet[ipt].set_type(ControlPoint::PointFromDem); // so we can track it later
        cnet[ipt].set_position(Vector3(point[0], point[1], point[2])); // update in the cnet too
        
        if (opt.heights_from_dem != "") {
          if (opt.heights_from_dem_weight <= 0) {
            // Fix it
            problem.SetParameterBlockConstant(point);
          }else{
            // Let it float. Later a constraint will be added.
            double s = 1.0/opt.heights_from_dem_weight;
            cnet[ipt].set_sigma(Vector3(s, s, s));
          }
          
        }else  if (opt.ref_dem != "") {
          if (opt.ref_dem_weight <= 0) {
            // Fix it
            problem.SetParameterBlockConstant(point);
          }else{
            // Let it float. Later a constraint will be added.
            double s = 1.0/opt.ref_dem_weight;
            cnet[ipt].set_sigma(Vector3(s, s, s));
          }
        }
      }

      // The observed value for the projection of point with index ipt into
      // the camera with index icam.
      Vector2 observation = (**fiter).m_location;
      Vector2 pixel_sigma = (**fiter).m_scale;

      // This is a bugfix
      if (pixel_sigma != pixel_sigma) // nan check
        pixel_sigma = Vector2(1, 1);

      double p = opt.overlap_exponent;
      if (p > 0 && count_map[ipt] > 2) {
        // Give more weight to points that are seen in more images.
        // This should not be overused. 
        double delta = pow(count_map[ipt] - 1.0, p);
        pixel_sigma /= delta;
      }

      // Call function to add the appropriate Ceres residual block.
      add_reprojection_residual_block(observation, pixel_sigma, ipt, icam,
                                      param_storage, opt, problem);
      cam_residual_counts[icam] += 1; // Track the number of residual blocks for each camera
      
    } // end iterating over points
  } // end iterating over cameras

  // Add ground control points or points based on a DEM constraint
  // Error goes up as GCP's move from their input positions.
  int num_gcp = 0, num_gcp_or_dem_residuals = 0;
  for (int ipt = 0; ipt < num_points; ipt++) {
    if (cnet[ipt].type() != ControlPoint::GroundControlPoint &&
        cnet[ipt].type() != ControlPoint::PointFromDem)
      continue; // Skip non-GCP's and points which do not need special treatment

    if (param_storage.get_point_outlier(ipt))
      continue; // skip outliers
    
    if (cnet[ipt].type() == ControlPoint::GroundControlPoint)
      num_gcp++;

    Vector3 observation = cnet[ipt].position();
    Vector3 xyz_sigma   = cnet[ipt].sigma();

    ceres::CostFunction* cost_function;
    if (!opt.use_llh_error) 
      cost_function = XYZError::Create(observation, xyz_sigma);
    else{
      Vector3 llh_sigma = xyz_sigma;
      // make lat,lon into lon,lat
      std::swap(llh_sigma[0], llh_sigma[1]);
      cost_function = LLHError::Create(observation, llh_sigma, opt.datum);
    }

    // Don't use the same loss function as for pixels since that one
    // discounts outliers and the GCP's should never be discounted.
    // The user an override this for the advanced --heights_from_dem
    // and --reference-dem options.
    ceres::LossFunction* loss_function = NULL;
    if (opt.heights_from_dem != ""      &&
        opt.heights_from_dem_weight > 0 &&
        opt.heights_from_dem_robust_threshold > 0) {
      loss_function = get_loss_function(opt, opt.heights_from_dem_robust_threshold);
    }else if (opt.ref_dem != "" &&
        opt.ref_dem_weight > 0  &&
        opt.ref_dem_robust_threshold > 0) {
      loss_function = get_loss_function(opt, opt.ref_dem_robust_threshold);
    }else{
      loss_function = new ceres::TrivialLoss();
    }
    double * point  = param_storage.get_point_ptr(ipt);
    problem.AddResidualBlock(cost_function, loss_function, point);

    num_gcp_or_dem_residuals++;

    if (opt.fix_gcp_xyz) 
      problem.SetParameterBlockConstant(point);
  } // End loop through GCP's

  // Add camera constraints
  // - Error goes up as cameras move and rotate from their input positions.
  if (opt.camera_weight > 0){
    for (int icam = 0; icam < num_cameras; icam++){
      double const* orig_cam_ptr = orig_parameters.get_camera_ptr(icam);
      ceres::CostFunction* cost_function = CamError::Create(orig_cam_ptr, opt.camera_weight);

      // Don't use the same loss function as for pixels since that one discounts
      //  outliers and the cameras should never be discounted.
      // TODO(oalexan1): This will prevent convergence in some cases!
      ceres::LossFunction* loss_function = new ceres::TrivialLoss();

      double * camera  = param_storage.get_camera_ptr(icam);
      problem.AddResidualBlock(cost_function, loss_function, camera);
    } // End loop through cameras.
  }

  // Finer level control of only rotation and translation.
  // - Error goes up as cameras move and rotate from their input positions.
  // TODO(oalexan1): This will prevent convergence in some cases as there is no attenuation
  if (opt.rotation_weight > 0 || opt.translation_weight > 0){
    for (int icam = 0; icam < num_cameras; icam++){
      double const* orig_cam_ptr = orig_parameters.get_camera_ptr(icam);
      ceres::CostFunction* cost_function
        = RotTransError::Create(orig_cam_ptr, opt.rotation_weight, opt.translation_weight);
      ceres::LossFunction* loss_function = new ceres::TrivialLoss();
      double * camera  = param_storage.get_camera_ptr(icam);
      problem.AddResidualBlock(cost_function, loss_function, camera);
    }
  }

  // TODO(oalexan1): Make this into a function in a separate file,
  // as it depends on Eigen which makes compilation even slower than
  // what it already is.
  // Add a cost function meant to tie up to known disparity
  // form left to right image and known ground truth reference terrain.
  // This was only tested for local pinhole cameras.
  // Disparity must be created with stereo -e 3 with the
  // option --unalign-disparity. If there are n images,
  // there must be n-1 disparities, from each image to the next.
  // The doc has more info in the bundle_adjust chapter.
  std::vector<ImageView<DispPixelT>> disp_vec;
  std::vector<ImageViewRef<DispPixelT>> interp_disp; 
  std::vector<vw::Vector3> reference_vec;
  if (opt.reference_terrain != "") {
    // TODO: Pass these properly
    g_max_disp_error           = opt.max_disp_error;
    g_reference_terrain_weight = opt.reference_terrain_weight;
    
    // Set up a GeoReference object using the datum, it may get modified later
    vw::cartography::GeoReference geo;
    geo.set_datum(opt.datum); // We checked for a datum earlier

    // Load the reference data
    std::vector<vw::Vector3> input_reference_vec;
    asp::load_csv_or_dem(opt.csv_format_str, opt.csv_proj4_str, opt.reference_terrain,  
                         opt.max_num_reference_points,  
                         geo,       // may change
                         input_reference_vec); // output

    if (load_reference_disparities(opt.disparity_list, disp_vec, interp_disp) != num_cameras-1)
      vw_throw(ArgumentErr() << "Expecting one less disparity than there are cameras.\n");
    
    std::vector<vw::BBox2i> image_boxes;
    for (int icam = 0; icam < num_cameras; icam++){
      DiskImageView<float> img(opt.image_files[icam]);
      BBox2i bbox = vw::bounding_box(img);
      image_boxes.push_back(bbox);
    }

    vw_out() << "Setting up the error to the reference terrain.\n";
    TerminalProgressCallback tpc("", "\t--> ");
    tpc.report_progress(0);
    double inc_amount = 1.0/double(input_reference_vec.size());

    reference_vec.clear();
    for (size_t data_col = 0; data_col < input_reference_vec.size(); data_col++) {

      vw::Vector3 reference_xyz = input_reference_vec[data_col];

      // Filter by lonlat box if provided, this is very much recommended
      // to quickly discard most points in the huge reference terrain.
      // Let's hope there is no 360 degree offset when computing
      // the longitude. 
      if ( asp::stereo_settings().lon_lat_limit != BBox2(0,0,0,0) ) {
        vw::Vector3 llh = geo.datum().cartesian_to_geodetic(reference_xyz);
        vw::Vector2 ll  = subvector(llh, 0, 2);
        if (!asp::stereo_settings().lon_lat_limit.contains(ll)) {
          continue;
        }
      }

      Vector2 left_pred, right_pred;

      // Iterate over the cameras, add a residual for each point and each camera pair.
      for (int icam = 0; icam < num_cameras - 1; icam++) {

        boost::shared_ptr<CameraModel> left_camera  = opt.camera_models[icam  ];
        boost::shared_ptr<CameraModel> right_camera = opt.camera_models[icam+1];

        try {
          left_pred  = left_camera->point_to_pixel (reference_xyz);
          right_pred = right_camera->point_to_pixel(reference_xyz);
        } catch (const camera::PointToPixelErr& e) {
          continue; // Skip point if there is a projection issue.
        }

        if ( (left_pred != left_pred) || (right_pred != right_pred) )
          continue; // nan check

        if (!interp_disp[icam].pixel_in_bounds(left_pred))
          continue; // Interp check

        DispPixelT dispPix = interp_disp[icam](left_pred[0], left_pred[1]);
        if (!is_valid(dispPix))
          continue;

        // Check if the current point projects in the cameras
        if ( !image_boxes[icam  ].contains(left_pred ) || 
             !image_boxes[icam+1].contains(right_pred)   ) {
          continue;
        }

        Vector2 right_pix = left_pred + dispPix.child();
        if (!image_boxes[icam+1].contains(right_pix)) 
          continue; // Check offset location too

        if (right_pix != right_pix || norm_2(right_pix - right_pred) > opt.max_disp_error) {
          // Ignore pixels which are too far from where they should be before optimization
          continue;
        }

        reference_vec.push_back(reference_xyz); // only the used reference points are stored here

        // Call function to select the appropriate Ceres residual block to add.
        add_disparity_residual_block(reference_xyz, interp_disp[icam],
                                     icam, icam+1, // left icam and right icam
                                     param_storage, opt, problem);
      }
      tpc.report_incremental_progress(inc_amount);
    }
    
    tpc.report_finished();
    vw_out() << "Found " << reference_vec.size() << " reference points in range.\n";
  } // End of reference terrain block

  int num_tri_residuals = 0;
  if (opt.tri_weight > 0) {
    // Add triangulation weight to make each triangulated point not move too far
    for (int ipt = 0; ipt < num_points; ipt++) {
      if (cnet[ipt].type() == ControlPoint::GroundControlPoint ||
          cnet[ipt].type() == ControlPoint::PointFromDem)
        continue; // Skip GCPs and height-from-dem points which have their own constraint
      
      if (param_storage.get_point_outlier(ipt))
        continue; // skip outliers
      
      double * point = param_storage.get_point_ptr(ipt);

      // Use as constraint the initially triangulated point
      Vector3 observation(point[0], point[1], point[2]);
      double s = 1.0/opt.tri_weight;
      Vector3 xyz_sigma(s, s, s);

      ceres::CostFunction* cost_function = XYZError::Create(observation, xyz_sigma);
      ceres::LossFunction* loss_function = get_loss_function(opt, opt.tri_robust_threshold);
      problem.AddResidualBlock(cost_function, loss_function, point);

      num_tri_residuals++;
    } // End loop through xyz
  } // end adding a triangulation constraint
  
  const size_t MIN_KML_POINTS = 50;
  size_t kmlPointSkip = 30;
  // Figure out a good KML point skip amount
  if (num_points / kmlPointSkip < MIN_KML_POINTS)
    kmlPointSkip = num_points / MIN_KML_POINTS;
  if (kmlPointSkip < 1)
    kmlPointSkip = 1;
    
  if (first_pass) {
    // Save the cnet 
    if (opt.save_cnet_as_csv) {
      std::string cnet_file = opt.out_prefix + "-cnet.csv";
      vw_out() << "Writing: " << cnet_file << std::endl;
      cnet.write_in_gcp_format(cnet_file, opt.datum);
    }
    
    
    std::string point_kml_path  = opt.out_prefix + "-initial_points.kml";
    std::string residual_prefix = opt.out_prefix + "-initial_residuals";
    vw_out() << "Writing initial condition files." << std::endl;
    bool apply_loss_function = false;
    write_residual_logs(residual_prefix, apply_loss_function, opt, param_storage, 
                        cam_residual_counts, num_gcp_or_dem_residuals, num_tri_residuals,
                        reference_vec, cnet, crn, problem);
    
    param_storage.record_points_to_kml(point_kml_path, opt.datum, 
                         kmlPointSkip, "initial_points",
                        "http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png");
  }

  // Solve the problem
  ceres::Solver::Options options;
  options.gradient_tolerance  = 1e-16;
  options.function_tolerance  = 1e-16;
  options.parameter_tolerance = opt.parameter_tolerance; // default is 1e-8

  options.max_num_iterations                = opt.num_iterations;
  options.max_num_consecutive_invalid_steps = std::max(5, opt.num_iterations/5); // try hard
  options.minimizer_progress_to_stdout      = true;

  if (opt.single_threaded_cameras)
    options.num_threads = 1;
  else
    options.num_threads = opt.num_threads;

  // Use a callback function at every iteration, if desired to save the intermediate results
  BaCallback callback(opt, param_storage);
  if (opt.save_intermediate_cameras) {
    options.callbacks.push_back(&callback);
    options.update_state_every_iteration = true;
  }

  // Set solver options according to the recommendations in the Ceres solving FAQs
  options.linear_solver_type = ceres::SPARSE_SCHUR;
  if (num_cameras < 100)
    options.linear_solver_type = ceres::DENSE_SCHUR;
  if (num_cameras > 3500) {
    // This is supposed to help with speed in a certain size range
    options.use_explicit_schur_complement = true; 
    options.linear_solver_type  = ceres::ITERATIVE_SCHUR;
    options.preconditioner_type = ceres::SCHUR_JACOBI;
  }
  if (num_cameras > 7000)
    options.use_explicit_schur_complement = false; // Only matters with ITERATIVE_SCHUR

  //options.ordering_type = ceres::SCHUR;
  //options.eta = 1e-3; // FLAGS_eta;
  //options->max_solver_time_in_seconds = FLAGS_max_solver_time;
  //options->use_nonmonotonic_steps = FLAGS_nonmonotonic_steps;
  //if (FLAGS_line_search) {
  //  options->minimizer_type = ceres::LINE_SEARCH;
  //}

  vw_out() << "Starting the Ceres optimizer." << std::endl;
  ceres::Solver::Summary summary;
  ceres::Solve(options, &problem, &summary);
  final_cost = summary.final_cost;
  vw_out() << summary.FullReport() << "\n";
  if (summary.termination_type == ceres::NO_CONVERGENCE){
    // Print a clarifying message, so the user does not think that the algorithm failed.
    vw_out() << "Found a valid solution, but did not reach the actual minimum." << std::endl;
    convergence_reached = false;
  }

  // Write the condition files after each pass, as we never know which pass will be the last
  // since we may stop the passes prematurely if no more outliers are present.
  vw_out() << "Writing final condition log files." << std::endl;
  std::string residual_prefix = opt.out_prefix + "-final_residuals";
  bool apply_loss_function = false;
  write_residual_logs(residual_prefix, apply_loss_function, opt, param_storage,
                      cam_residual_counts,
                      num_gcp_or_dem_residuals, num_tri_residuals,
                      reference_vec, cnet, crn, problem);
  
  std::string point_kml_path = opt.out_prefix + "-final_points.kml";
  std::string url = "http://maps.google.com/mapfiles/kml/shapes/placemark_circle_highlight.png";
  param_storage.record_points_to_kml(point_kml_path, opt.datum, kmlPointSkip, "final_points",
                                     url);
  
  // Print the stats for GCP
  // TODO(oalexan1): This should go to a file
  if (num_gcp > 0) 
    param_storage.print_gcp_stats(cnet, opt.datum);

  // Outlier filtering
  bool remove_outliers = (opt.num_ba_passes > 1);
  if (remove_outliers)
      add_to_outliers(cnet, crn,
                      param_storage,   // in-out
                      opt, cam_residual_counts, num_gcp_or_dem_residuals,
                      num_tri_residuals, reference_vec, problem);

  // Find the cameras with the latest adjustments. Note that we do not modify
  // opt.camera_models, but make copies as needed.
  std::vector<vw::CamPtr> optimized_cams;
  calcOptimizedCameras(opt, param_storage, optimized_cams);
  
  // Calculate convergence angles. Remove the outliers flagged earlier,
  // if remove_outliers is true. Compute offsets of mapprojected matches,
  // if a DEM is given. These are done together as they rely on
  // reloading interest point matches, which is expensive so the matches
  // are used for both operations.
  std::vector<vw::Vector<float, 4>> mapprojPoints; // all points, not just stats
  std::vector<asp::MatchPairStats> convAngles, mapprojOffsets;
  std::vector<std::vector<float>> mapprojOffsetsPerCam;
  vw::cartography::GeoReference mapproj_dem_georef;
  if (!opt.mapproj_dem.empty()) {
    bool is_good = vw::cartography::read_georeference(mapproj_dem_georef, opt.mapproj_dem);
    if (!is_good) 
      vw::vw_throw(vw::ArgumentErr() << "Could not read a georeference from: "
                   << opt.mapproj_dem << ".\n");
  }
  outliers.clear(); 
  for (int i = 0; i < param_storage.num_points(); i++)
    if (param_storage.get_point_outlier(i))
      outliers.insert(i); // update this based on param_storage
  asp::matchFilesProcessing(cnet,
                            asp::BaBaseOptions(opt), // note the slicing
                            optimized_cams, remove_outliers, outliers, opt.mapproj_dem,
                            convAngles, mapprojPoints, mapprojOffsets, mapprojOffsetsPerCam);

  std::string conv_angles_file = opt.out_prefix + "-convergence_angles.txt";
  asp::saveConvergenceAngles(conv_angles_file, convAngles, opt.image_files);

  if (!opt.mapproj_dem.empty()) {
    std::string mapproj_offsets_stats_file = opt.out_prefix + "-mapproj_match_offset_stats.txt";
    std::string mapproj_offsets_file = opt.out_prefix + "-mapproj_match_offsets.txt";
    asp::saveMapprojOffsets(mapproj_offsets_stats_file, mapproj_offsets_file,
                            mapproj_dem_georef,
                            mapprojPoints,
                            mapprojOffsets, 
                            mapprojOffsetsPerCam, // will change
                            opt.image_files);
  }
  
  return 0;
} // End function do_ba_ceres_one_pass

/// Use Ceres to do bundle adjustment.
void do_ba_ceres(Options & opt, std::vector<Vector3> const& estimated_camera_gcc){

  // Try to set up the control network, ie the list of point coordinates.
  // - This triangulates from the camera models to determine the initial
  //   world coordinate estimate for each matched IP.
  opt.cnet.reset(new ControlNetwork("BundleAdjust"));
  int num_gcp = 0;
  ControlNetwork & cnet = *(opt.cnet.get()); // alias
  if (!opt.apply_initial_transform_only) {
    bool triangulate_control_points = true;
    bool success = vw::ba::build_control_network(triangulate_control_points,
                                                 cnet, opt.camera_models,
                                                 opt.image_files,
                                                 opt.match_files,
                                                 opt.min_matches,
                                                 opt.min_triangulation_angle*(M_PI/180.0),
                                                 opt.forced_triangulation_distance,
                                                 opt.max_pairwise_matches);
    if (!success) {
      vw_out() << "Failed to build a control network.\n"
               << " - Consider removing all .vwip and .match files and \n"
               << "   increasing the number of interest points per tile using\n "
               << "   --ip-per-tile, or decreasing --min-matches.\n"
               << " - Check if your images are similar enough in illumination,\n"
               << "   and if they have enough overlap.\n"   
               << "Will continue if ground control points are present.\n";
    }
    vw_out() << "Loading GCP files...\n";
    num_gcp = vw::ba::add_ground_control_points(cnet, opt.gcp_files, opt.datum);
  }
  
  // If we change the cameras, we must rebuild the control network
  bool cameras_changed = false;
  
  // If camera positions were provided for local inputs, align to them.
  const bool have_est_camera_positions = (opt.camera_position_file != "");
  if ((opt.camera_type == BaCameraType_Pinhole) && have_est_camera_positions) {
    asp::init_pinhole_model_with_camera_positions(opt.cnet, opt.camera_models,
                                                  opt.image_files, estimated_camera_gcc);
    cameras_changed = true;
  }

  // If we have GPC's for pinhole cameras, try to do a simple affine
  // initialization of the camera parameters.
  // - This function also updates all the ControlNetwork world point
  //   positions.
  // - We could do this for other camera types too, but it would
  //   require us to be able to adjust our camera model positions.
  //   Otherwise we could init the adjustment values.
  if (opt.gcp_files.size() > 0) {
    if ((opt.camera_type == BaCameraType_Pinhole) && 
        !have_est_camera_positions) {
      if (opt.transform_cameras_using_gcp) {
        asp::transform_cameras_with_indiv_image_gcp(opt.cnet, opt.camera_models);
        cameras_changed = true;
      } else if (opt.transform_cameras_with_shared_gcp) {
        asp::transform_cameras_with_shared_gcp(opt.cnet, opt.camera_models);
            cameras_changed = true;
      } else if (opt.init_camera_using_gcp) {
        asp::init_camera_using_gcp(opt.cnet, opt.camera_models);
            cameras_changed = true;
      }
    }
    
    // Issue a warning if the GCPs are far away from the camera coordinates.
    // Do it only if the cameras did not change, as otherwise the cnet is outdated.
    if (!cameras_changed) 
      check_gcp_dists(opt.camera_models, opt.cnet, opt.forced_triangulation_distance);
  }
  
  int num_points = cnet.size();
  const int num_cameras = opt.image_files.size();

  // This is important to prevent a crash later
  if (num_points == 0 && !opt.apply_initial_transform_only) {
    vw_out() << "No points to optimize (GCP or otherwise). Cannot continue.\n";
    return;
  }
  
  // Create the storage arrays for the variables we will adjust.
  int num_lens_distortion_params = 0;
  if (opt.camera_type == BaCameraType_Pinhole) {
    boost::shared_ptr<vw::camera::PinholeModel> pinhole_ptr = 
            boost::dynamic_pointer_cast<vw::camera::PinholeModel>(opt.camera_models[0]);
    num_lens_distortion_params = pinhole_ptr->lens_distortion()->distortion_parameters().size();
    if (num_lens_distortion_params < 1) {
      // For the case where the camera has zero distortion parameters, use one dummy parameter
      //  just so we don't have to change the parameter block logic later on.
      num_lens_distortion_params = 1;
      opt.intrinisc_options.distortion_constant = true;
      opt.intrinisc_options.distortion_shared   = true;
    }
  }
  if (opt.camera_type == BaCameraType_OpticalBar) {
    num_lens_distortion_params = NUM_OPTICAL_BAR_EXTRA_PARAMS; // TODO: Share this constant!
  }
  asp::BAParams param_storage(num_points, num_cameras,
                               // Optical bar and pinhole are similar
                               opt.camera_type != BaCameraType_Other, 
                               // Must be the same for each pinhole camera
                               num_lens_distortion_params, 
                               opt.intrinisc_options);

  // Fill in the camera and intrinsic parameters.
  std::vector<boost::shared_ptr<camera::CameraModel>> new_cam_models;
  bool ans = false;
  switch (opt.camera_type) {
    case BaCameraType_Pinhole:
      ans = init_cams_pinhole(opt, param_storage, new_cam_models); break;
    case BaCameraType_OpticalBar:
      ans = init_cams_optical_bar(opt, param_storage, new_cam_models); break;
    default:
      ans = init_cams(opt, param_storage, new_cam_models);
  };

  if (ans)
    cameras_changed = true;
  
  // Certain input options change the cameras inside init_cams and we
  // need to update the point coordinates for the new cameras. It is
  // ok to leave the original vector of camera models unchanged.
  
  // TODO(oalexan1): Building the control network twice looks like a
  // hack. Try to understand why the cameras can't be updated first,
  // then building the control network just once.
  if (!opt.apply_initial_transform_only && cameras_changed) {
    vw_out() <<"Updating the control network." << std::endl;
    cnet = ControlNetwork("Updated network"); // Wipe it all first
    /*bool success = */
    // Building the control network below may fail if there are only GCP,
    // but we will continue nevertheless.
    bool triangulate_control_points = true;
    vw::ba::build_control_network(triangulate_control_points,
                                  cnet, new_cam_models,
                                  opt.image_files,
                                  opt.match_files,
                                  opt.min_matches,
                                  opt.min_triangulation_angle*(M_PI/180.0),
                                  opt.forced_triangulation_distance,
                                  opt.max_pairwise_matches);
    
    // Restore the rest of the cnet object
    num_gcp = vw::ba::add_ground_control_points(cnet, opt.gcp_files, opt.datum);
    
    check_gcp_dists(new_cam_models, opt.cnet, opt.forced_triangulation_distance);
    
    // Must update the number of points after the control network is recomputed
    num_points = cnet.size();
    param_storage.get_point_vector().resize(num_points*asp::BAParams::PARAMS_PER_POINT);
  }

  // Fill in the point vector with the starting values.
  for (int ipt = 0; ipt < num_points; ipt++)
    param_storage.set_point(ipt, cnet[ipt].position());

  // The camera positions and orientations before we float them
  // - This includes modifications from any initial transforms that were specified.
  asp::BAParams orig_parameters(param_storage);

  bool has_datum = (opt.datum.name() != asp::UNSPECIFIED_DATUM);
  if (has_datum && (opt.stereo_session == "pinhole") || 
      (opt.stereo_session == "nadirpinhole")) 
    saveCameraReport(opt, param_storage,  opt.datum, "initial");
    
  // TODO(oalexan1): Is it possible to avoid using CRNs?
  CRNJ crn;
  crn.from_cnet(cnet);

  if (opt.num_ba_passes <= 0)
    vw_throw(ArgumentErr() << "Error: Expecting at least one bundle adjust pass.\n");
  
  double final_cost;
  for (int pass = 0; pass < opt.num_ba_passes; pass++) {

    if (opt.apply_initial_transform_only)
      continue;
      
    vw_out() << "--> Bundle adjust pass: " << pass << std::endl;

    bool first_pass = (pass == 0);
    bool convergence_reached = true; // will change
    do_ba_ceres_one_pass(opt, crn, first_pass,
                         param_storage, orig_parameters,
                         convergence_reached, final_cost);
    
    int num_points_remaining = num_points - param_storage.get_num_outliers();
    if (num_points_remaining < opt.min_matches && num_gcp == 0) {
      // Do not throw if there exist gcp, as maybe that's all there is, and there
      // can be just a few of them.
      vw_throw(ArgumentErr() << "Error: Too few points remain after filtering!.\n");
    }
  } // End loop through passes

  double best_cost = final_cost;
  boost::shared_ptr<asp::BAParams> best_params_ptr(new asp::BAParams(param_storage));

  // This flow is only kicked in if opt.num_random_passes is positive, which
  // is not the default.
  std::string orig_out_prefix = opt.out_prefix;
  for (int pass = 0; pass < opt.num_random_passes; pass++) {

    if (opt.apply_initial_transform_only)
      continue;
    
    vw_out() << "\n--> Running bundle adjust pass " << pass 
             << " with random initial parameter offsets.\n";

    // Randomly distort the original inputs.
    param_storage.randomize_cameras();
    if (opt.solve_intrinsics)
      param_storage.randomize_intrinsics(opt.intrinsics_limits); // This handles sharing, etc.

    // Write output files to a temporary prefix
    opt.out_prefix = orig_out_prefix + "_rand";

    // Do another pass of bundle adjustment.
    bool first_pass = true; // this needs more thinking
    bool convergence_reached = true;
    do_ba_ceres_one_pass(opt, crn, first_pass,
                         param_storage, orig_parameters,
                         convergence_reached, final_cost);
    
    // Record the parameters of the best result.
    if (final_cost < best_cost) {
      vw_out() << "  --> Found a better solution!\n\n";
      best_cost = final_cost;
      best_params_ptr.reset(new asp::BAParams(param_storage));

      // Get a list of all the files that were generated in the random step.
      std::vector<std::string> rand_files;
      get_files_with_prefix(opt.out_prefix, rand_files);

      // Replace the existing output files with them.
      for (size_t i=0; i<rand_files.size(); i++) {
        std::string new_path = rand_files[i];
        boost::replace_all(new_path, opt.out_prefix, orig_out_prefix);
        boost::filesystem::copy_file(rand_files[i], new_path,
                                     boost::filesystem::copy_option::overwrite_if_exists);
      }
    }

    // Clear out the extra files that were generated
    std::string cmd("rm -f " + opt.out_prefix + "*");
    vw_out() << "Deleting temporary files: " << cmd << std::endl;
    vw::exec_cmd(cmd.c_str());
  }
  opt.out_prefix = orig_out_prefix; // So the cameras are written to the expected paths.

  // Write the results to disk.
  saveResults(opt, *best_params_ptr);

  if (has_datum && (opt.stereo_session == "pinhole") || 
      (opt.stereo_session == "nadirpinhole")) 
    saveCameraReport(opt, *best_params_ptr, opt.datum, "final");
  
} // end do_ba_ceres

/// Looks in the input camera position file to generate a GCC position for
/// each input camera.
/// - If no match is found, the coordinate is (0,0,0)
int load_estimated_camera_positions(Options &opt,
                                    std::vector<Vector3> & estimated_camera_gcc) {
  estimated_camera_gcc.clear();
  if (opt.camera_position_file == "")
    return 0;
  
  // Read the input csv file
  asp::CsvConv conv;
  conv.parse_csv_format(opt.csv_format_str, opt.csv_proj4_str);
  std::list<asp::CsvConv::CsvRecord> pos_records;
  typedef std::list<asp::CsvConv::CsvRecord>::const_iterator RecordIter;
  conv.read_csv_file(opt.camera_position_file, pos_records);

  // Set up a GeoReference object using the datum
  vw::cartography::GeoReference geo;
  geo.set_datum(opt.datum); // We checked for a datum earlier
  // Use user's csv_proj4 string, if provided, to add info to the georef.
  conv.parse_georef(geo);

  // For each input camera, find the matching position in the record list
  const int num_cameras = opt.image_files.size();
  estimated_camera_gcc.resize(num_cameras);
  
  const RecordIter no_match = pos_records.end();
  int num_matches_found = 0;
  for (int i=0; i<num_cameras; i++) {

    // Search for this image file in the records
    std::string file_name = opt.image_files[i];
    RecordIter iter;
    for (iter=pos_records.begin(); iter!=pos_records.end(); iter++) {
      // Match if the string in the file is contained in the input image string.
      // - May need to play around with this in the future!
      std::string field = iter->file;
      if (file_name.find(field) != std::string::npos) {
        estimated_camera_gcc[i] = conv.csv_to_cartesian(*iter, geo);
        break; // Match found, stop the iterator here.
      }
    }
    if (iter == no_match) {
      vw_out() << "WARNING: Camera file " << file_name << " not found in camera position file.\n";
      estimated_camera_gcc[i] = Vector3(0,0,0);
    }else
      ++num_matches_found;
  } // End loop to find position record for each camera

  return num_matches_found;  
}

void handle_arguments(int argc, char *argv[], Options& opt) {
  const double nan = std::numeric_limits<double>::quiet_NaN();
  std::string intrinsics_to_float_str, intrinsics_to_share_str,
    intrinsics_limit_str;
  bool  inline_adjustments;
  int   max_iterations_tmp;
  po::options_description general_options("");
  general_options.add_options()
    ("output-prefix,o",  po::value(&opt.out_prefix), "Prefix for output filenames.")
    ("cost-function",    po::value(&opt.cost_function)->default_value("Cauchy"),
     "Choose a cost function from: Cauchy, PseudoHuber, Huber, L1, L2, Trivial.")
    ("robust-threshold", po::value(&opt.robust_threshold)->default_value(0.5),
     "Set the threshold for robust cost functions. Increasing this makes the solver focus harder on the larger errors.")
    ("inline-adjustments",   po::bool_switch(&inline_adjustments)->default_value(false),
     "If this is set, and the input cameras are of the pinhole or panoramic type, apply the adjustments directly to the cameras, rather than saving them separately as .adjust files.")
    ("approximate-pinhole-intrinsics", po::bool_switch(&opt.approximate_pinhole_intrinsics)->default_value(false),
     "If it reduces computation time, approximate the lens distortion model.")
    ("solve-intrinsics",    po::bool_switch(&opt.solve_intrinsics)->default_value(false)->implicit_value(true),
     "Optimize intrinsic camera parameters.  Only used for pinhole cameras.")
    ("intrinsics-to-float", po::value(&intrinsics_to_float_str)->default_value(""),
     "If solving for intrinsics and desired to float only a few of them, specify here, in quotes, one or more of: focal_length, optical_center, other_intrinsics. Not specifying anything will float all of them.")
    ("intrinsics-to-share", po::value(&intrinsics_to_share_str)->default_value(""),
     "If solving for intrinsics and desired to share only a few of them, specify here, in quotes, one or more of: focal_length, optical_center, other_intrinsics. Not specifying anything, will share none of them.")
    ("intrinsics-limits", 
     po::value(&intrinsics_limit_str)->default_value(""),
     "Specify minimum and maximum ratios for the intrinsic parameters. Values must be in min max pairs and are applied in the order [focal length, optical center, other intrinsics] until all of the limits are used. Check the documentation to dermine how many intrinsic parameters are used for your cameras.")
    ("camera-positions",    po::value(&opt.camera_position_file)->default_value(""),
     "Specify a csv file path containing the estimated positions of the input cameras.  Only used with the inline-adjustments option.")
    ("init-camera-using-gcp",  po::bool_switch(&opt.init_camera_using_gcp)->default_value(false)->implicit_value(true),
     "Given an image, a pinhole camera lacking correct position and orientation, and a GCP file, find the pinhole camera with given intrinsics most consistent with the GCP.")
    ("transform-cameras-with-shared-gcp",  po::bool_switch(&opt.transform_cameras_with_shared_gcp)->default_value(false)->implicit_value(true),
    "Given at least 3 GCP, with each seen in at least 2 images, "
    "find the triangulated positions based on pixels values in the GCP, "
    "and apply a rotation + translation + scale transform to the entire "
    "camera system so that the triangulated points get mapped to the ground "
     "coordinates in the GCP.")
    ("transform-cameras-using-gcp",  po::bool_switch(&opt.transform_cameras_using_gcp)->default_value(false)->implicit_value(true),
     "Given a set of GCP, with at least two images having at least three GCP each (but with each GCP not shared among the images), transform the cameras to ground coordinates. This is not as robust as --transform-cameras-with-shared-gcp.")
    ("disable-pinhole-gcp-init",  po::bool_switch(&opt.disable_pinhole_gcp_init)->default_value(false)->implicit_value(true),
     "Do not try to initialize the positions of pinhole cameras based on input GCPs. This ignored as is now the default. See also: --init-camera-using-gcp.")
    ("input-adjustments-prefix",  po::value(&opt.input_prefix),
     "Prefix to read initial adjustments from, written by a previous invocation of this program.")
    ("initial-transform",   po::value(&opt.initial_transform_file)->default_value(""),
     "Before optimizing the cameras, apply to them the 4x4 rotation + translation transform from this file. The transform is in respect to the planet center, such as written by pc_align's source-to-reference or reference-to-source alignment transform. Set the number of iterations to 0 to stop at this step. If --input-adjustments-prefix is specified, the transform gets applied after the adjustments are read.")
    ("fixed-camera-indices",    po::value(&opt.fixed_cameras_indices_str)->default_value(""),
     "A list of indices, in quotes and starting from 0, with space as separator, corresponding to cameras to keep fixed during the optimization process.")
    ("fixed-image-list",    po::value(&opt.fixed_image_list)->default_value(""),
     "A file having a list of images (separated by spaces or newlines) whose cameras should be fixed during optimization.")
    ("fix-gcp-xyz",       po::bool_switch(&opt.fix_gcp_xyz)->default_value(false)->implicit_value(true),
     "If the GCP are highly accurate, use this option to not float them during the optimization.")

    ("csv-format",        po::value(&opt.csv_format_str)->default_value(""), asp::csv_opt_caption().c_str())
    ("csv-proj4",         po::value(&opt.csv_proj4_str)->default_value(""),
     "The PROJ.4 string to use to interpret the entries in input CSV files.")
    ("reference-terrain", po::value(&opt.reference_terrain)->default_value(""),
     "An externally provided trustworthy 3D terrain, either as a DEM or as a lidar file, very close (after alignment) to the stereo result from the given images and cameras that can be used as a reference, instead of GCP, to optimize the intrinsics of the cameras.")
    ("max-num-reference-points", po::value(&opt.max_num_reference_points)->default_value(100000000),
     "Maximum number of (randomly picked) points from the reference terrain to use.")
    ("disparity-list",           po::value(&opt.disparity_list)->default_value(""),
     "The unaligned disparity files to use when optimizing the intrinsics based on a reference terrain. Specify them as a list in quotes separated by spaces. First file is for the first two images, second is for the second and third images, etc. If an image pair has no disparity file, use 'none'.")
    ("max-disp-error",           po::value(&opt.max_disp_error)->default_value(-1),
     "When using a reference terrain as an external control, ignore as outliers xyz points which projected in the left image and transported by disparity to the right image differ by the projection of xyz in the right image by more than this value in pixels.")
    ("reference-terrain-weight", po::value(&opt.reference_terrain_weight)->default_value(1.0),
     "How much weight to give to the cost function terms involving the reference terrain.")
    ("heights-from-dem",   po::value(&opt.heights_from_dem)->default_value(""),
     "If the cameras have already been bundle-adjusted and aligned to a known high-quality DEM, "
     "in the triangulated xyz points replace the heights with the ones from this DEM, and "
     "fix those points unless --heights-from-dem-weight is positive.")
    ("heights-from-dem-weight", po::value(&opt.heights_from_dem_weight)->default_value(1.0),
     "How much weight to give to keep the triangulated points close to the DEM if specified via "
     "--heights-from-dem. If the weight is not positive, keep the triangulated points fixed. "
     "This value should be inversely proprortional with ground sample distance, as "
     "then it will convert the measurements from meters to pixels, which is consistent "
     "with the reprojection error term.")
    ("heights-from-dem-robust-threshold",
     po::value(&opt.heights_from_dem_robust_threshold)->default_value(0.5),
     "If positive, this is the robust threshold to use keep the triangulated points "
     "close to the DEM if specified via --heights-from-dem. This is applied after the "
     "point differences are multiplied by --heights-from-dem-weight. It should help with "
     "attenuating large height difference outliers.")
    ("mapproj-dem", po::value(&opt.mapproj_dem)->default_value(""),
     "If specified, mapproject every pair of matched interest points onto this DEM and compute "
     "their distance, then percentiles of such distances for each image pair and "
     "for each image vs the rest. "
     "This is done after bundle adjustment and outlier removal. "
     "Measured in meters.")
    ("reference-dem",  po::value(&opt.ref_dem)->default_value(""),
     "If specified, intersect rays from matching pixels with this DEM, find the average, and constrain during optimization that rays keep on intersecting close to this point. This works even when the rays are almost parallel, but then consider using the option --forced-triangulation-distance. See also --reference-dem-weight and --reference-dem-robust-threshold.")
    ("reference-dem-weight", po::value(&opt.ref_dem_weight)->default_value(1.0),
     "Multiply the xyz differences for the --reference-dem option by this weight.")
    ("reference-dem-robust-threshold", po::value(&opt.ref_dem_robust_threshold)->default_value(0.5),
     "Use this robust threshold for the weighted xyz differences with the --reference-dem option.")
    ("datum",            po::value(&opt.datum_str)->default_value(""),
     "Use this datum. Needed only for ground control points, a camera position file, or for RPC sessions. Options: WGS_1984, D_MOON (1,737,400 meters), D_MARS (3,396,190 meters), MOLA (3,396,000 meters), NAD83, WGS72, and NAD27. Also accepted: Earth (=WGS_1984), Mars (=D_MARS), Moon (=D_MOON).")
    ("semi-major-axis",  po::value(&opt.semi_major)->default_value(0),
     "Explicitly set the datum semi-major axis in meters (see above).")
    ("semi-minor-axis",  po::value(&opt.semi_minor)->default_value(0),
     "Explicitly set the datum semi-minor axis in meters (see above).")
    ("session-type,t",   po::value(&opt.stereo_session)->default_value(""),
     "Select the stereo session type to use for processing. Usually the program can select this automatically by the file extension, except for xml cameras. See the doc for options.")
    ("min-matches",      po::value(&opt.min_matches)->default_value(30),
     "Set the minimum  number of matches between images that will be considered.")
    ("max-pairwise-matches", po::value(&opt.max_pairwise_matches)->default_value(10000),
     "Reduce the number of matches per pair of images to at most this "
     "number, by selecting a random subset, if needed. This happens "
     "when setting up the optimization, and before outlier filtering.")
    ("ip-detect-method", po::value(&opt.ip_detect_method)->default_value(0),
     "Interest point detection algorithm (0: Integral OBALoG (default), 1: OpenCV SIFT, 2: OpenCV ORB.")
    ("epipolar-threshold",      po::value(&opt.epipolar_threshold)->default_value(-1),
     "Maximum distance from the epipolar line to search for IP matches. Default: automatic calculation. A higher values will result in more matches.")
    ("ip-inlier-factor",        po::value(&opt.ip_inlier_factor)->default_value(0.2),
     "A higher factor will result in more interest points, but perhaps also more outliers. This is used only with homography alignment, such as for the pinhole session.")
    ("ip-uniqueness-threshold", po::value(&opt.ip_uniqueness_thresh)->default_value(0.8),
     "A higher threshold will result in more interest points, but perhaps less unique ones.")
    ("ip-side-filter-percent",  po::value(&opt.ip_edge_buffer_percent)->default_value(-1),
     "Remove matched IPs this percentage from the image left/right sides.")
    ("normalize-ip-tiles", 
     po::bool_switch(&opt.ip_normalize_tiles)->default_value(false)->implicit_value(true),
     "Individually normalize tiles used for IP detection.")
    ("num-obalog-scales",      po::value(&opt.num_scales)->default_value(-1),
     "How many scales to use if detecting interest points with OBALoG. If not specified, 8 will be used. More can help for images with high frequency artifacts.")
    ("nodata-value",           po::value(&opt.nodata_value)->default_value(nan),
     "Pixels with values less than or equal to this number are treated as no-data. This overrides the no-data values from input images.")
    ("num-iterations",       po::value(&opt.num_iterations)->default_value(1000),
     "Set the maximum number of iterations.") 
    ("max-iterations",       po::value(&max_iterations_tmp)->default_value(1000),
     "Set the maximum number of iterations.") // alias for num-iterations
    ("parameter-tolerance",  po::value(&opt.parameter_tolerance)->default_value(1e-8),
     "Stop when the relative error in the variables being optimized is less than this.")
    ("overlap-limit",        po::value(&opt.overlap_limit)->default_value(0),
     "Limit the number of subsequent images to search for matches to the current image to this value. By default match all images.")
    ("overlap-list",         po::value(&opt.overlap_list_file)->default_value(""),
     "A file containing a list of image pairs, one pair per line, separated by a space, which are expected to overlap. Matches are then computed only among the images in each pair.")
    ("auto-overlap-params",  po::value(&opt.auto_overlap_params)->default_value(""),
     "Determine which camera images overlap by finding the lon-lat bounding boxes "
     "of their footprints given the specified DEM, expanding them by a given percentage, "
     "and see if those intersect. A higher percentage should be used when there is more "
     "uncertainty about the input camera poses. Example: 'dem.tif 15'.")
    ("auto-overlap-buffer",  po::value(&opt.auto_overlap_buffer)->default_value(-1.0),
     "Try to automatically determine which images overlap. Used only if "
     "this option is explicitly set. Only supports Worldview style XML "
     "camera files. The lon-lat footprints of the cameras are expanded "
     "outwards on all sides by this value (in degrees), before checking "
     "if they intersect.")
    ("image-list", po::value(&opt.image_list)->default_value(""),
     "A file containing the list of images, when they are too many to specify on the command line. Use space or newline as separator. See also --camera-list and --mapprojected-data-list.")
    ("camera-list", po::value(&opt.camera_list)->default_value(""),
     "A file containing the list of cameras, when they are too many to specify on the command "
     "line. If the images have embedded camera information, such as for ISIS, this file must "
     "be empty but must be specified if --image-list is specified.")
    ("mapprojected-data-list", po::value(&opt.mapprojected_data_list)->default_value(""),
     "A file containing the list of mapprojected images and the DEM (see --mapprojected-data), when they are too many to specify on the command line.")
    ("position-filter-dist", po::value(&opt.position_filter_dist)->default_value(-1),
     "Set a distance in meters and don't perform IP matching on images with an estimated camera center farther apart than this distance.  Requires --camera-positions.")
    ("match-first-to-last", po::value(&opt.match_first_to_last)->default_value(false)->implicit_value(true),
     "Match first several images to last several images by extending the logic of --overlap-limit past the last image to the earliest ones.")
    
    ("rotation-weight",      po::value(&opt.rotation_weight)->default_value(0.0),
     "A higher weight will penalize more rotation deviations from the original configuration.")
    ("translation-weight",   po::value(&opt.translation_weight)->default_value(0.0),
     "A higher weight will penalize more translation deviations from the original configuration.")
    ("camera-weight",        po::value(&opt.camera_weight)->default_value(1.0),
     "The weight to give to the constraint that the camera positions/orientations stay close to the original values. A higher weight means that the values will change less. The options --rotation-weight and --translation-weight can be used for finer-grained control.")
    ("tri-weight", po::value(&opt.tri_weight)->default_value(0.0),
     "The weight to give to the constraint that optimized triangulated "
     "points stay close to original triangulated points. A positive value will help "
     "ensure the cameras do not move too far, but a large value may prevent convergence. "
     "It is suggested to use here 0.1 to 0.5 divided by image gsd. Use it together with "
     "--tri-robust-threshold. Does not apply to GCP or points constrained by a DEM. "
     "Set --camera-weight to 0 when using this.")
    ("tri-robust-threshold",
     po::value(&opt.tri_robust_threshold)->default_value(0.1),
     "Use this robust threshold to attenuate large differences "
     "between initial and optimized triangulation points, after multiplying them by --tri-weight.")
    ("overlap-exponent",     po::value(&opt.overlap_exponent)->default_value(0.0),
     "If a feature is seen in n >= 2 images, give it a weight proportional with (n-1)^exponent.")
    ("ip-per-tile",          po::value(&opt.ip_per_tile)->default_value(0),
      "How many interest points to detect in each 1024^2 image tile (default: automatic determination). This is before matching. Not all interest points will have a match. See also --matches-per-tile.")
    ("ip-per-image",              po::value(&opt.ip_per_image)->default_value(0),
     "How many interest points to detect in each image (default: automatic determination). It is overridden by --ip-per-tile if provided.")
    ("num-passes",           po::value(&opt.num_ba_passes)->default_value(2),
     "How many passes of bundle adjustment to do, with given number of iterations in each pass. For more than one pass, outliers will be removed between passes using --remove-outliers-params, and re-optimization will take place. Residual files and a copy of the match files with the outliers removed (*-clean.match) will be written to disk.")
    ("num-random-passes",           po::value(&opt.num_random_passes)->default_value(0),
     "After performing the normal bundle adjustment passes, do this many more passes using the same matches but adding random offsets to the initial parameter values with the goal of avoiding local minima that the optimizer may be getting stuck in.")
    ("remove-outliers-params", 
     po::value(&opt.remove_outliers_params_str)->default_value("75.0 3.0 2.0 3.0", "'pct factor err1 err2'"),
     "Outlier removal based on percentage, when more than one bundle adjustment pass is used. Triangulated points (that are not GCP) with reprojection error in pixels larger than min(max('pct'-th percentile * 'factor', err1), err2) will be removed as outliers. Hence, never remove errors smaller than err1 but always remove those bigger than err2. Specify as a list in quotes. Also remove outliers based on distribution of interest point matches and triangulated points. Default: '75.0 3.0 2.0 3.0'.")
    ("elevation-limit",        po::value(&opt.elevation_limit)->default_value(Vector2(0,0), "auto"),
     "Remove as outliers interest points (that are not GCP) for which the elevation of the triangulated position (after cameras are optimized) is outside of this range. Specify as two values: min max.")
    // Note that we count later on the default for lon_lat_limit being BBox2(0,0,0,0).
    ("lon-lat-limit",          po::value(&opt.lon_lat_limit)->default_value(BBox2(0,0,0,0), "auto"),
     "Remove as outliers interest points (that are not GCP) for which the longitude and latitude of the triangulated position (after cameras are optimized) are outside of this range. Specify as: min_lon min_lat max_lon max_lat.")
    ("match-files-prefix",  po::value(&opt.match_files_prefix)->default_value(""),
     "Use the match files from this prefix instead of the current output prefix. This implies --skip-matching.")
    ("clean-match-files-prefix",  po::value(&opt.clean_match_files_prefix)->default_value(""),
     "Use as input match files the *-clean.match files from this prefix. This implies --skip-matching.")
    ("enable-rough-homography",
     po::bool_switch(&opt.enable_rough_homography)->default_value(false)->implicit_value(true),
     "Enable the step of performing datum-based rough homography for interest point matching. This is best used with reasonably reliable input cameras and a wide footprint on the ground.")
    ("skip-rough-homography",
     po::bool_switch(&opt.skip_rough_homography)->default_value(false)->implicit_value(true),
     "Skip the step of performing datum-based rough homography. This obsolete option is ignored as is the default.")
    ("enable-tri-ip-filter",
     po::bool_switch(&opt.enable_tri_filtering)->default_value(false)->implicit_value(true),
     "Enable triangulation-based interest points filtering. This is best used with reasonably reliable input cameras.")
    ("disable-tri-ip-filter",
     po::bool_switch(&opt.disable_tri_filtering)->default_value(false)->implicit_value(true),
     "Disable triangulation-based interest points filtering. This obsolete option is ignored as is the default.")
    ("no-datum", po::bool_switch(&opt.no_datum)->default_value(false)->implicit_value(true),
     "Do not assume a reliable datum exists, such as for irregularly shaped bodies.")
    ("individually-normalize", 
     po::bool_switch(&opt.individually_normalize)->default_value(false)->implicit_value(true),
     "Individually normalize the input images instead of using common values.")
    ("ip-triangulation-max-error",  po::value(&opt.ip_triangulation_max_error)->default_value(-1),
     "When matching IP, filter out any pairs with a triangulation error higher than this.")
    ("ip-num-ransac-iterations", po::value(&opt.ip_num_ransac_iterations)->default_value(1000),
     "How many RANSAC iterations to do in interest point matching.")
    ("min-triangulation-angle", po::value(&opt.min_triangulation_angle)->default_value(0.1),
     "A triangulated point will be accepted as valid only if at "
     "least two of the rays which converge at it have a triangulation "
     "angle of at least this (measured in degrees).")
    ("forced-triangulation-distance",      po::value(&opt.forced_triangulation_distance)->default_value(-1),
     "When triangulation fails, for example, when input cameras are inaccurate, artificially create a triangulation point this far ahead of the camera, in units of meter.")
    ("use-lon-lat-height-gcp-error",
     po::bool_switch(&opt.use_llh_error)->default_value(false)->implicit_value(true),
     "When having GCP, interpret the three standard deviations in the GCP file as applying not to x, y, and z, but rather to latitude, longitude, and height.")
    ("enable-correct-velocity-aberration", po::bool_switch(&opt.enable_correct_velocity_aberration)->default_value(false)->implicit_value(true),
     "Turn on velocity aberration correction for Optical Bar and non-ISIS linescan cameras. This option impairs the convergence of bundle adjustment.")
    ("enable-correct-atmospheric-refraction", po::bool_switch(&opt.enable_correct_atmospheric_refraction)->default_value(false)->implicit_value(true),
     "Turn on atmospheric refraction correction for Optical Bar and non-ISIS linescan cameras. This option impairs the convergence of bundle adjustment.")
    ("dg-use-csm", po::bool_switch(&opt.dg_use_csm)->default_value(false)->implicit_value(true),
     "Use the CSM model with DigitalGlobe linescan cameras (-t dg). No corrections are done for velocity aberration or atmospheric refraction.")
    ("mapprojected-data",  po::value(&opt.mapprojected_data)->default_value(""),
     "Given map-projected versions of the input images and the DEM they "
     "were mapprojected onto, create interest point matches among the  "
     "mapprojected images, unproject and save those matches, then  "
     "continue with bundle adjustment. Existing match files will be  "
     "reused. Specify the mapprojected images and the DEM as a string in  "
     "quotes, separated by spaces. An example is in the documentation.")
    ("matches-per-tile",  po::value(&opt.matches_per_tile)->default_value(0),
     "How many interest point matches to compute in each image tile (of size "
      "normally 1024^2 pixels). Use a value of --ip-per-tile a few times larger "
      "than this. See also --matches-per-tile-params.")
    ("save-cnet-as-csv", po::bool_switch(&opt.save_cnet_as_csv)->default_value(false)->implicit_value(true),
     "Save the control network containing all interest points in the format used by ground control points, so it can be inspected.")
    ("gcp-from-mapprojected-images", po::value(&opt.gcp_from_mapprojected)->default_value(""),
     "Given map-projected versions of the input images, the DEM the were mapprojected onto, and interest point matches among all of these created in stereo_gui, create GCP for the input images to align them better to the DEM. This is experimental and not documented.")
    ("instance-count",      po::value(&opt.instance_count)->default_value(1),
     "The number of bundle_adjustment processes being run in parallel.")
    ("instance-index",      po::value(&opt.instance_index)->default_value(0),
     "The index of this parallel bundle adjustment process.")
    ("stop-after-statistics",    po::bool_switch(&opt.stop_after_stats)->default_value(false)->implicit_value(true),
     "Quit after computing image statistics.")
    ("stop-after-matching",    po::bool_switch(&opt.stop_after_matching)->default_value(false)->implicit_value(true),
     "Quit after writing all match files.")
    ("force-reuse-match-files", po::bool_switch(&opt.force_reuse_match_files)->default_value(false)->implicit_value(true),
     "Force reusing the match files even if older than the images or cameras.")
    ("skip-matching",    po::bool_switch(&opt.skip_matching)->default_value(false)->implicit_value(true),
     "Only use image matches which can be loaded from disk. This implies --force-reuse-match-files.")
    ("save-intermediate-cameras", po::value(&opt.save_intermediate_cameras)->default_value(false)->implicit_value(true),
     "Save the values for the cameras at each iteration.")
    ("apply-initial-transform-only", po::value(&opt.apply_initial_transform_only)->default_value(false)->implicit_value(true),
     "Apply to the cameras the transform given by --initial-transform. "
     "No iterations, GCP loading, image matching, or report generation "
     "take place. Using --num-iterations 0 and without this option "
     "will create those.")
    ("proj-win", po::value(&opt.proj_win)->default_value(BBox2(0,0,0,0), "auto"),
     "Flag as outliers input triangulated points not in this proj win (box in projected units as provided by --proj_str). This should be generous if the input cameras have significant errors.")
    ("proj-str",   po::value(&opt.proj_str)->default_value(""),
     "To be used in conjunction with --proj_win.")
    ("matches-per-tile-params",  po::value(&opt.matches_per_tile_params)->default_value(Vector2(1024, 1280), "1024 1280"),
     "To be used with --matches-per-tile. The first value is the image tile "
      "size for both images. A larger second value allows each right tile to "
      "further expand to this size, resulting in the tiles overlapping. This may be "
      "needed if the homography alignment between these images is not great, as "
      "this transform is used to pair up left and right image tiles.")
    ("save-vwip",    po::bool_switch(&opt.save_vwip)->default_value(false)->implicit_value(true),
     "Save .vwip files (intermediate files for creating .match files). For parallel_bundle_adjust these will be saved in subdirectories, as they depend on the image pair. Must start with an empty output directory for this to work.")
    ("vwip-prefix",  po::value(&opt.vwip_prefix),
     "Save .vwip files with this prefix. This is a private option used by parallel_bundle_adjust.")
    ("ip-debug-images",        po::value(&opt.ip_debug_images)->default_value(false)->implicit_value(true),
     "Write debug images to disk when detecting and matching interest points.");
    
  general_options.add(vw::GdalWriteOptionsDescription(opt));

  po::options_description positional("");
  positional.add_options()
    ("input-files", po::value(&opt.image_files));

  po::positional_options_description positional_desc;
  positional_desc.add("input-files", -1);

  std::string usage("<images> <cameras> <optional ground control points> -o <output prefix> [options]");
  bool allow_unregistered = false;
  std::vector<std::string> unregistered;
  po::variables_map vm =
    asp::check_command_line(argc, argv, opt, general_options, general_options,
                            positional, positional_desc, usage,
                             allow_unregistered, unregistered);

  // Separate out GCP files
  opt.gcp_files = asp::get_files_with_ext(opt.image_files, ".gcp", true);
  const size_t num_gcp_files = opt.gcp_files.size();
  vw_out() << "Found " << num_gcp_files << " GCP files on the command line.\n";

  // Separate the cameras from the images
  std::vector<std::string> inputs = opt.image_files;

  if (!opt.image_list.empty()) {
    // Read the images and cameras and put them in 'inputs' to be parsed later
    if (opt.camera_list.empty())
      vw_throw(ArgumentErr()
               << "The option --image-list must be invoked together with --camera-list.\n");
    if (!inputs.empty())
      vw_throw(ArgumentErr() << "The option --image-list was specified, but also "
               << "images or cameras on the command line.\n");
    asp::read_list(opt.image_list, inputs);
    std::vector<std::string> tmp;
    asp::read_list(opt.camera_list, tmp);
    for (size_t it = 0; it < tmp.size(); it++) 
      inputs.push_back(tmp[it]);
  }

  // Sanity checks
  if ((!opt.camera_list.empty() || !opt.mapprojected_data_list.empty()) && opt.image_list.empty())
    vw_throw(ArgumentErr() << "Found --camera-list and --mapprojected-data-list, "
             << "but not --image-list.\n");
  if (!opt.mapprojected_data.empty() && !opt.mapprojected_data_list.empty())
    vw_throw(ArgumentErr() << "Cannot specify both --mapprojected-data and "
             << "--mapprojected-data-list.\n");
  
  bool ensure_equal_sizes = true;
  asp::separate_images_from_cameras(inputs,
                                    opt.image_files, opt.camera_files, // outputs
                                    ensure_equal_sizes); 
  
  asp::check_for_duplicates(opt.image_files, opt.camera_files, opt.out_prefix);
  
  // Sanity check
  if (opt.image_files.size() != (int)opt.camera_files.size()){
    vw_out() << "Detected " << opt.image_files.size() << " images and "
             << opt.camera_files.size() << " cameras.\n";
    vw_throw(ArgumentErr() << "Must have as many cameras as we have images.\n");
  }
  
  // TODO: Check for duplicates in opt.image_files!

  if (opt.image_files.empty())
    vw_throw( ArgumentErr() << "Missing input image files.\n"
                            << usage << general_options );

  // TODO(oalexan1): This duplicates logic from StereoSessionFactory.cc.
  // But need to ensure nothing breaks below.

  // Reusing match files implies that we skip matching
  if (opt.clean_match_files_prefix != "" || opt.match_files_prefix != "")
    opt.skip_matching = true;
  
  //  When skipping matching, we are already forced to reuse match
  //  files based on the logic in the code, but here enforce it
  //  explicitly anyway.
  if (opt.skip_matching) 
    opt.force_reuse_match_files = true;

  if (opt.auto_overlap_params != "" && opt.skip_matching) {
    vw_out() << "Ignoring --auto-overlap-params since no matching takes place.\n";
    opt.auto_overlap_params = "";
  }
  
  // Work out the camera model type to use
  boost::to_lower(opt.stereo_session);
  opt.camera_type = BaCameraType_Other;
  if (inline_adjustments) {

    // Try to guess the session 
    if (opt.stereo_session == ""){
      try {
        // If we can open a pinhole camera file, that means
        // we are good. We prefer nadirpinhole to pinhole
        // session.
        PinholeModel(opt.camera_files[0]);
        opt.stereo_session = "nadirpinhole";
      }catch(std::exception const& e){}
    }
    
    if ((opt.stereo_session == "pinhole") || 
        (opt.stereo_session == "nadirpinhole")) {
      opt.camera_type = BaCameraType_Pinhole;
    } else {
      if (opt.stereo_session == "opticalbar")
        opt.camera_type = BaCameraType_OpticalBar;
      else
        vw_throw( ArgumentErr() << "Cannot use inline adjustments with session: "
                  << opt.stereo_session << "\n"
                                << usage << general_options );
    }
  } // End resolving the model type
  
  if (opt.transform_cameras_using_gcp &&
      (!inline_adjustments) &&
      (opt.camera_type != BaCameraType_Pinhole)) {
    vw_throw( ArgumentErr() << "Transforming cameras using GCP works only for pinhole "
              << "cameras and with the --inline-adjustments flag.\n"
              << usage << general_options );
  }
  
  if (opt.overlap_list_file != "" && opt.overlap_limit > 0)
    vw_throw( ArgumentErr() << "Cannot specify both the overlap limit and the overlap list.\n"
              << usage << general_options );

  if (opt.overlap_list_file != "" && opt.match_first_to_last > 0)
    vw_throw( ArgumentErr() << "Cannot specify both the overlap limit and --match-first-to-last.\n"
              << usage << general_options );
    
  if (opt.overlap_limit < 0)
    vw_throw( ArgumentErr() << "Must allow search for matches between "
              << "at least each image and its subsequent one.\n" << usage << general_options );
  
  // By default, try to match all of the images!
  if (opt.overlap_limit == 0)
    opt.overlap_limit = opt.image_files.size();

  if (int(opt.overlap_list_file != "") + int(!vm["auto-overlap-buffer"].defaulted()) +
      int(opt.auto_overlap_params != "") > 1)
    vw_throw( ArgumentErr() << "Cannot specify more than one of --overlap-list, "
              << "--auto-overlap-params, and --auto-overlap-buffer.\n"
              << usage << general_options);

  opt.have_overlap_list = false;
  if (opt.overlap_list_file != "") {
   opt.have_overlap_list = true;
    if (!fs::exists(opt.overlap_list_file))
      vw_throw( ArgumentErr() << "The overlap list does not exist.\n" << usage
                << general_options );
    opt.overlap_list.clear();
    std::string image1, image2;
    std::ifstream ifs(opt.overlap_list_file.c_str());
    while (ifs >> image1 >> image2){
      opt.overlap_list.insert(std::make_pair(image1, image2));
      opt.overlap_list.insert(std::make_pair(image2, image1));
    }
    ifs.close();
  } else if (!vm["auto-overlap-buffer"].defaulted()) {
    opt.have_overlap_list = true;
    auto_build_overlap_list(opt, opt.auto_overlap_buffer);
  }
  // The third alternative, --auto-overlap-params will be handled when we have cameras
  
  if (opt.camera_weight < 0.0)
    vw_throw( ArgumentErr() << "The camera weight must be non-negative.\n" << usage
                            << general_options );

  if ( opt.rotation_weight < 0.0 )
    vw_throw( ArgumentErr() << "The rotation weight must be non-negative.\n" << usage
                            << general_options );

  if ( opt.translation_weight < 0.0 )
    vw_throw( ArgumentErr() << "The translation weight must be non-negative.\n" << usage
                            << general_options );

  if (opt.tri_weight < 0.0)
    vw_throw( ArgumentErr() << "The triangulation weight must be non-negative.\n" << usage
              << general_options );
  
  if (opt.tri_weight > 0 && opt.camera_weight > 0) 
    vw_throw( ArgumentErr() << "When --tri-weight is positive, set to zero "
              << "--camera-weight. Can use --rotation-weight and --translation-weight.\n");
  
  // NOTE(oalexan1): The reason min_triangulation_angle cannot be 0 is deep inside
  // StereoModel.cc. Better keep it this way than make too many changes there.
  if (opt.min_triangulation_angle <= 0.0)
    vw_throw( ArgumentErr() << "The minimum triangulation angle must be positive.\n");
  
  // TODO: Make sure the normal model loading catches this error.
  //if (opt.create_pinhole && !asp::has_pinhole_extension(opt.camera_files[0]))
  //  vw_throw( ArgumentErr() << "Cannot use special pinhole handling with non-pinhole input!\n");

  if ((opt.camera_type == BaCameraType_Other) && opt.solve_intrinsics)
    vw_throw( ArgumentErr() << "Solving for intrinsic parameters is only supported with "
              << "pinhole and optical bar cameras.\n");

  if ((opt.camera_type!=BaCameraType_Pinhole) && opt.approximate_pinhole_intrinsics)
    vw_throw( ArgumentErr() << "Cannot approximate intrinsics unless using pinhole cameras.\n");

  if (opt.approximate_pinhole_intrinsics && opt.solve_intrinsics)
    vw_throw( ArgumentErr() << "Cannot approximate intrinsics while solving for them.\n");

  if (opt.camera_type != BaCameraType_Other &&
      opt.camera_type != BaCameraType_Pinhole &&
      opt.input_prefix != "")
    vw_throw( ArgumentErr() << "Can only use initial adjustments with camera type "
              << "'other' or 'pinhole'. Here likely having optical bar cameras.\n");

  vw::string_replace(opt.remove_outliers_params_str, ",", " "); // replace any commas
  opt.remove_outliers_params = vw::str_to_vec<vw::Vector<double, 4>>(opt.remove_outliers_params_str);
  
  // Ensure good order
  if ( opt.lon_lat_limit != BBox2(0,0,0,0) ) {
    if ( opt.lon_lat_limit.min().y() > opt.lon_lat_limit.max().y() ) 
      std::swap( opt.lon_lat_limit.min().y(), opt.lon_lat_limit.max().y() );
    if ( opt.lon_lat_limit.min().x() > opt.lon_lat_limit.max().x() ) 
      std::swap( opt.lon_lat_limit.min().x(), opt.lon_lat_limit.max().x() );
  }
  
  if (!opt.camera_position_file.empty() && opt.csv_format_str == "")
    vw_throw( ArgumentErr() << "When using a camera position file, the csv-format "
              << "option must be set.\n");

  if (opt.max_pairwise_matches <= 0) 
    vw_throw( ArgumentErr() << "Must have a positive number of max pairwise matches.\n");
  
  // Copy the IP settings to the global stereo_settings() object
  opt.copy_to_asp_settings();

  // Try to infer the datum, if possible, from the images. For
  // example, Cartosat-1 has that info in the Tif file.
  bool guessed_datum = false;
  if (opt.datum_str == "") {
    vw::cartography::GeoReference georef;
    for (size_t it = 0; it < opt.image_files.size(); it++) {
      bool is_good = vw::cartography::read_georeference(georef, opt.image_files[it]);
      if (is_good){
        opt.datum = georef.datum();
        opt.datum_str = opt.datum.name();
        guessed_datum = true;
      }
    }
  }

  // Try to infer the datum from the reference terrain
  if (opt.reference_terrain != "") {
    std::string file_type = asp::get_cloud_type(opt.reference_terrain);
    if (file_type == "DEM") {
      vw::cartography::GeoReference georef;
      bool is_good = vw::cartography::read_georeference(georef, opt.reference_terrain);
      if (!is_good)
        vw_throw( ArgumentErr() << "The reference terrain DEM does not have a georeference.\n");
      if (opt.datum_str == ""){
        opt.datum = georef.datum();
        opt.datum_str = opt.datum.name();
        guessed_datum = true;
      }
    }
  }

  if (opt.robust_threshold <= 0.0) 
    vw_throw(ArgumentErr() << "The value of --robust-threshold must be positive.\n");

  if (opt.tri_robust_threshold <= 0.0) 
    vw_throw(ArgumentErr() << "The value of --tri-robust-threshold must be positive.\n");

  if ((!opt.heights_from_dem.empty() || !opt.ref_dem.empty()) && opt.fix_gcp_xyz)
    vw_throw(ArgumentErr()
             << "The option --fix-gcp-xyz is not compatible with a DEM constraint.\n");
  
  if (!opt.heights_from_dem.empty() && !opt.ref_dem.empty()) 
    vw_throw(ArgumentErr() << "Cannot specify more than one of: --heights-from-dem "
             << "and --reference-dem.\n");

  if (opt.heights_from_dem_weight < 0.0) 
    vw_throw(ArgumentErr() << "The value of --heights-from-dem-weight must be non-negative.\n");
  
  if (opt.heights_from_dem_robust_threshold < 0.0) 
    vw_throw(ArgumentErr() << "The value of --heights-from-robust-threshold must be non-negative.\n");

  if (opt.ref_dem_weight <= 0.0) 
    vw_throw(ArgumentErr() << "The value of --reference-dem-weight must be positive.\n");
  
  if (opt.ref_dem_robust_threshold <= 0.0) 
    vw_throw(ArgumentErr() << "The value of --reference-dem-robust-threshold must be positive.\n");

  bool have_dem = (!opt.heights_from_dem.empty() || !opt.ref_dem.empty());
  
  // Try to infer the datum from the heights-from-dem
  std::string dem_file;
  if (opt.heights_from_dem != "") 
    dem_file = opt.heights_from_dem;
  else if (opt.ref_dem != "")
    dem_file = opt.ref_dem;
  if (dem_file != "") {
    std::string file_type = asp::get_cloud_type(dem_file);
    if (file_type == "DEM") {
      vw::cartography::GeoReference georef;
      bool is_good = vw::cartography::read_georeference(georef, dem_file);
      if (!is_good)
        vw_throw( ArgumentErr() << "The DEM " << dem_file
                  << " does not have a georeference.\n");

      if (opt.datum_str == "" ) {
        opt.datum = georef.datum();
        opt.datum_str = opt.datum.name();
        guessed_datum = true;
      }
    }
  }
  
  // Set the datum, either based on what the user specified or the axes
  if (opt.datum_str != "" && !guessed_datum) {
    try {
      opt.datum.set_well_known_datum(opt.datum_str);
    } catch(...) {
      // Whatever datum name we had, it was bad, so we'll make more attempts below
      opt.datum_str = "";
      guessed_datum = false;
    }
  }else if (opt.semi_major > 0 && opt.semi_minor > 0){
    // Otherwise, if the user set the semi-axes, use that.
    opt.datum = cartography::Datum("User Specified Datum",
                                   "User Specified Spheroid",
                                   "Reference Meridian",
                                   opt.semi_major, opt.semi_minor, 0.0);
    opt.datum_str = opt.datum.name();
    guessed_datum = true;
  }

  // Otherwise try to set the datum based on cameras.  It will return
  // WGS84 if all else fails.
  // TODO(oalexan1): That may not be desirable with ground-level cameras.
  if (opt.datum_str == "") {
    asp::datum_from_cameras(opt.image_files, opt.camera_files,  
                            opt.stereo_session,  // may change
                            // Outputs
                            opt.datum);
    opt.datum_str = opt.datum.name();
  }
  
  // Many times the datum is mandatory
  if (opt.datum_str == "") {
    if (!opt.gcp_files.empty() || !opt.camera_position_file.empty() )
      vw_throw( ArgumentErr() << "When ground control points or a camera position file are used, "
                << "the datum must be specified.\n");
    
    if (opt.elevation_limit[0] < opt.elevation_limit[1])
      vw_throw( ArgumentErr()
                << "When filtering by elevation limit, the datum must be specified.\n");
  }

  vw_out() << "Will use the datum:\n" << opt.datum << std::endl;

  // This is a little clumsy, but need to see whether the user set --max-iterations
  // or --num-iterations. They are aliases to each other.
  if (!vm["max-iterations"].defaulted() && !vm["num-iterations"].defaulted()) 
    vw_throw( ArgumentErr() << "Cannot set both --num-iterations and --max-iterations.\n");
  if (!vm["max-iterations"].defaulted())
    opt.num_iterations = max_iterations_tmp;
  
  if ( opt.out_prefix.empty() )
    vw_throw( ArgumentErr() << "Missing output prefix.\n" << usage << general_options  );

  // Create the output directory
  vw::create_out_dir(opt.out_prefix);

  // Turn on logging to file
  asp::log_to_file(argc, argv, "", opt.out_prefix);

  opt.load_intrinsics_options(intrinsics_to_float_str, intrinsics_to_share_str,
                              !vm["intrinsics-to-share"].defaulted());

  opt.parse_intrinsics_limits(intrinsics_limit_str);

  boost::to_lower(opt.cost_function);

  if (opt.apply_initial_transform_only && opt.initial_transform_file == "")
    vw_throw(vw::IOErr() << "Cannot use --apply-initial-transform-only "
              << "without --initial-transform.\n");
  
  if (opt.initial_transform_file != "") {
    vw_out() << "Reading the alignment transform from: " << opt.initial_transform_file << "\n";
    vw::read_matrix_as_txt(opt.initial_transform_file, opt.initial_transform);
    if (opt.initial_transform.cols() != 4 || opt.initial_transform.rows() != 4)
      vw_throw(ArgumentErr() << "Could not read the initial transform.\n");
    vw_out() << "Initial transform:\n" << opt.initial_transform << std::endl;
  }

  // Parse the indices of cameras not to float
  if (opt.fixed_cameras_indices_str != "") {
    opt.fixed_cameras_indices.clear();
    std::istringstream is(opt.fixed_cameras_indices_str);
    int val;
    while (is >> val) {
      opt.fixed_cameras_indices.insert(val);
      if (val < 0 || val >= (int)opt.image_files.size()) 
        vw_throw( vw::IOErr() << "The camera index to keep fixed " << val
                              << " is out of bounds.\n" );
    }
  }

  if (!opt.fixed_cameras_indices.empty() && !opt.fixed_image_list.empty())
    vw_throw(ArgumentErr() << "Cannot specify both --fixed-camera-indices and "
             << "--fixed-image-list.\n");
  if (!opt.fixed_image_list.empty()) {

    opt.fixed_cameras_indices.clear();
    
    std::vector<std::string> fixed_images;
    asp::read_list(opt.fixed_image_list, fixed_images);

    // Find the indices of all images
    std::map<std::string, int> all_indices;
    for (size_t image_it = 0; image_it < opt.image_files.size(); image_it++) 
      all_indices[opt.image_files[image_it]] = image_it;

    // Find the indices of images to fix
    for (size_t image_it = 0; image_it < fixed_images.size(); image_it++) {
      auto map_it = all_indices.find(fixed_images[image_it]);
      if (map_it == all_indices.end())
        vw_throw(ArgumentErr() << "Could not find image " << fixed_images[image_it]
                 << " read via --fixed-image-list among the input images.\n");
      opt.fixed_cameras_indices.insert(map_it->second);
    }
  }
  
  if (opt.reference_terrain != "") {
    std::string file_type = asp::get_cloud_type(opt.reference_terrain);
    if (file_type == "CSV" && opt.csv_format_str == "") 
      vw_throw( ArgumentErr() << "When using a csv reference terrain, "
                              << "must specify the csv-format.\n");
    if (opt.datum_str == "")
      vw_throw( ArgumentErr() << "When using a reference terrain, must specify the datum.\n");
    if (opt.disparity_list == "") 
      vw_throw( ArgumentErr() << "When using a reference terrain, must specify a list "
                              << "of disparities.\n");
    if (opt.max_disp_error <= 0) 
      vw_throw( ArgumentErr() << "Must specify --max-disp-error in pixels as a positive value.\n");
    if (opt.reference_terrain_weight < 0) 
      vw_throw( ArgumentErr() << "The value of --reference-terrain-weight must be non-negative.\n");
  }

  if (opt.match_files_prefix != "" && opt.clean_match_files_prefix != "") 
    vw_throw( ArgumentErr()
              << "Cannot specify both --match-files-prefix and --clean-match-files-prefix.\n");

  if (int(opt.proj_win != BBox2(0, 0, 0, 0)) + int(!opt.proj_str.empty()) == 1)
    vw_throw(ArgumentErr() << "Must specify both or neither of --proj-win and --proj-str.\n");

  if (int(opt.transform_cameras_using_gcp) +
      int(opt.transform_cameras_with_shared_gcp) +
      int(opt.init_camera_using_gcp) > 1)
    vw::vw_throw(vw::ArgumentErr()
                 << "Cannot specify more than one of --transform-cameras-using-gcp, "
                 << "transform-cameras-with-shared-gcp, init-camera-using-gcp.\n");

  return;
}

// A wrapper around ip matching. Can also work with NULL cameras.
void ba_match_ip(Options & opt, SessionPtr session, 
                 std::string const& image1_path,  std::string const& image2_path,
                 vw::camera::CameraModel* cam1,   vw::camera::CameraModel* cam2,
                 std::string const& match_filename) {
  
  boost::shared_ptr<DiskImageResource>
    rsrc1(vw::DiskImageResourcePtr(image1_path)),
    rsrc2(vw::DiskImageResourcePtr(image2_path));
  if ( (rsrc1->channels() > 1) || (rsrc2->channels() > 1) )
    vw_throw(ArgumentErr()
             << "Error: Input images can only have a single channel!\n\n");
  float nodata1, nodata2;
  asp::get_nodata_values(rsrc1, rsrc2, nodata1, nodata2);

  // IP matching may not succeed for all pairs
  
  // Get masked views of the images to get statistics from
  DiskImageView<float> image1_view(rsrc1), image2_view(rsrc2);
  ImageViewRef< PixelMask<float> > masked_image1
    = create_mask_less_or_equal(image1_view,  nodata1);
  ImageViewRef< PixelMask<float> > masked_image2
    = create_mask_less_or_equal(image2_view, nodata2);
  
  // Since we computed statistics earlier, this will just be loading files.
  vw::Vector<vw::float32,6> image1_stats, image2_stats;
  image1_stats = asp::gather_stats(masked_image1, image1_path, 
                                   opt.out_prefix, image1_path);
  image2_stats = asp::gather_stats(masked_image2, image2_path, 
                                   opt.out_prefix, image2_path);
  
  // Do not save by default .vwip files as those take space and are
  // not needed after a match file is created. If the user wants them,
  // they must be saved in a subdirectory for each match pair, as
  // .vwip files change depending on the pair.
  std::string ip_file1 = "", ip_file2 = "";
  if (opt.save_vwip) {
      // parallel_bundle_adjust should have set vwip_prefix, but not bundle_adjust itself
    if (opt.vwip_prefix == "")
      opt.vwip_prefix = opt.out_prefix; 
    
    ip_file1 = ip::ip_filename(opt.vwip_prefix, image1_path); 
    ip_file2 = ip::ip_filename(opt.vwip_prefix, image2_path);
    vw::create_out_dir(opt.vwip_prefix);
  }
  
  // The match files (.match) are cached unless the images or camera
  // are newer than them.
  session->ip_matching(image1_path, image2_path,
                       Vector2(masked_image1.cols(), masked_image1.rows()),
                       image1_stats, image2_stats, 
                       nodata1, nodata2, cam1, cam2, match_filename, 
                       ip_file1, ip_file2);
}

//==================================================================================
// Mapprojected image functions.

/// If the user map-projected the images (this is useful when the
/// perspective or illumination conditions are too different, and
/// automated matching fails), first create matches among the
/// mapprojected images (or use any such matches created beforehand
/// manually by the user), and project those matches into the cameras,
/// creating matches between the raw images that then bundle_adjust
/// can use. Both matches between mapprojected images and between
/// original images are saved to files.
void matches_from_mapproj_images(int i, int j,
                                 Options& opt, SessionPtr session,
                                 std::vector<std::string> const& map_files,
                                 vw::cartography::GeoReference const& dem_georef,
                                 ImageViewRef<PixelMask<double>> & interp_dem,
                                 std::string const& match_filename){
  
  vw::cartography::GeoReference georef1, georef2;
  vw_out() << "Reading georef from " << map_files[i] << ' ' << map_files[j] << std::endl;
  bool is_good1 = vw::cartography::read_georeference(georef1, map_files[i]);
  bool is_good2 = vw::cartography::read_georeference(georef2, map_files[j]);
  if (!is_good1 || !is_good2) {
    vw_throw(ArgumentErr() << "Error: Cannot read georeference.\n");
  }
  
  std::string image1_path  = opt.image_files[i];
  std::string image2_path  = opt.image_files[j];
  if (boost::filesystem::exists(match_filename)) {
    vw_out() << "Using cached match file: " << match_filename << "\n";
    return;
  }

  if (opt.skip_matching)
    return;

  // If the match file does not exist, create it. The user can create this manually
  // too. 
  std::string map_match_file = ip::match_filename(opt.out_prefix,
                                                  map_files[i], map_files[j]);
  try{
    
    ba_match_ip(opt, session, map_files[i], map_files[j],
                NULL, NULL, // cameras are set to null since images are mapprojected
                map_match_file);
  } catch ( const std::exception& e ){
    vw_out() << "Could not find interest points between images "
             << map_files[i] << " and " << map_files[j] << std::endl;
    vw_out(WarningMessage) << e.what() << std::endl;
    return;
  } //End try/catch
  
  if (!boost::filesystem::exists(map_match_file)) {
    vw_out() << "Missing: " << map_match_file << "\n";
    return;
  }

  vw_out() << "Reading: " << map_match_file << std::endl;
  std::vector<ip::InterestPoint> ip1,     ip2;
  std::vector<ip::InterestPoint> ip1_cam, ip2_cam;
  ip::read_binary_match_file(map_match_file, ip1, ip2);
  
  // Undo the map-projection
  for (size_t ip_iter = 0; ip_iter < ip1.size(); ip_iter++) {
    
    vw::ip::InterestPoint P1 = ip1[ip_iter];
    vw::ip::InterestPoint P2 = ip2[ip_iter];
    if (!asp::projected_ip_to_raw_ip(P1, interp_dem, opt.camera_models[i], georef1, dem_georef))
      continue;
    if (!asp::projected_ip_to_raw_ip(P2, interp_dem, opt.camera_models[j], georef2, dem_georef))
      continue;
    
    ip1_cam.push_back(P1);
    ip2_cam.push_back(P2);
  }
  
  vw_out() << "Saving " << ip1_cam.size() << " matches.\n";
  
  vw_out() << "Writing: " << match_filename << std::endl;
  ip::write_binary_match_file(match_filename, ip1_cam, ip2_cam);

} // End function matches_from_mapproj_images()

/// If the user map-projected the images and created matches by hand
/// from each map-projected image to the DEM it was map-projected onto,
/// project those matches back into the camera image, and create gcp
/// tying each camera image match to its desired location on the DEM.
void create_gcp_from_mapprojected_images(Options const& opt){

  // Read the map-projected images and the dem
  std::istringstream is(opt.gcp_from_mapprojected);
  std::vector<std::string> image_files;
  std::string file;
  while (is >> file){
    image_files.push_back(file); 
  }
  std::string dem_file = image_files.back();
  image_files.erase(image_files.end() - 1); // wipe the dem from the list

  vw::cartography::GeoReference dem_georef;
  ImageViewRef<PixelMask<double>> interp_dem;
  asp::create_interp_dem(dem_file, dem_georef, interp_dem);

  int num_images = image_files.size();
  std::vector<std::vector<vw::ip::InterestPoint> > matches;
  std::vector<vw::cartography::GeoReference> img_georefs;
  matches.resize(num_images + 1); // the last match will be for the DEM

  // Read the matches and georefs
  for (int i = 0; i < num_images; i++) {

    vw::cartography::GeoReference img_georef;
    vw_out() << "Reading georef from " << image_files[i]  << std::endl;
    bool is_good_img = vw::cartography::read_georeference(img_georef, image_files[i]);
    if (!is_good_img) {
      vw_throw(ArgumentErr() << "Error: Cannot read georeference.\n");
    }
    img_georefs.push_back(img_georef);

    std::string match_filename = ip::match_filename(opt.out_prefix,
                                                    image_files[i], dem_file);
    if (!boost::filesystem::exists(match_filename)) 
      vw_throw(ArgumentErr() << "Missing: " << match_filename << ".\n");

    vw_out() << "Reading: " << match_filename << std::endl;
    std::vector<ip::InterestPoint> ip1, ip2;
    ip::read_binary_match_file(match_filename, ip1, ip2);

    if (matches[num_images].size() > 0 && matches[num_images].size() != ip2.size()) {
      vw_throw(ArgumentErr() << "All match files must have the same number of IP.\n");
    }
    matches[i]          = ip1;
    matches[num_images] = ip2;
  }

  std::vector<std::vector<vw::ip::InterestPoint> > cam_matches = matches;

  std::string gcp_file;
  for (int i = 0; i < num_images; i++) {
    gcp_file += boost::filesystem::basename(opt.image_files[i]);
    if (i < num_images - 1) gcp_file += "__"; 
  }
  gcp_file = opt.out_prefix + "-" + gcp_file + ".gcp";

  vw_out() << "Writing: " << gcp_file << std::endl;
  std::ofstream output_handle(gcp_file.c_str());
  output_handle.precision(17);
  
  int num_ips = matches[0].size();
  int pts_count = 0;
  for (int p = 0; p < num_ips; p++) { // Loop through IPs

    // Compute the GDC coordinate of the point
    ip::InterestPoint dem_ip = matches[num_images][p];
    Vector2 dem_pixel(dem_ip.x, dem_ip.y);
    Vector2 lonlat = dem_georef.pixel_to_lonlat(dem_pixel);

    if (!interp_dem.pixel_in_bounds(dem_pixel)) {
      vw_out() << "Skipping pixel outside of DEM: " << dem_pixel << std::endl;
      continue;
    }

    PixelMask<float> mask_height = interp_dem(dem_pixel[0], dem_pixel[1])[0];
    if (!is_valid(mask_height)) continue;

    Vector3 llh(lonlat[0], lonlat[1], mask_height.child());
    //Vector3 dem_xyz = dem_georef.datum().geodetic_to_cartesian(llh);

    // The ground control point ID
    output_handle << pts_count;
    // Lat, lon, height
    output_handle << ", " << lonlat[1] << ", " << lonlat[0] << ", " << mask_height.child();
    // Sigma values
    output_handle << ", " << 1 << ", " << 1 << ", " << 1;

    // Write the per-image information
    for (int i = 0; i < num_images; i++) {

      // Take the ip in the map-projected image, and back-project it into the camera
      ip::InterestPoint ip = matches[i][p];
      if (!asp::projected_ip_to_raw_ip(ip, interp_dem, opt.camera_models[i],
                                  img_georefs[i], dem_georef))
          continue;

      // TODO: Here we can have a book-keeping problem!
      cam_matches[i][p] = ip;

      output_handle << ", " << opt.image_files[i];
      output_handle << ", " << ip.x << ", " << ip.y; // IP location in image
      output_handle << ", " << 1 << ", " << 1; // Sigma values
    } // End loop through IP sets
    output_handle << std::endl; // Finish the line
    pts_count++;

  } // End loop through IPs
  output_handle.close();

  // Write out match files for each pair of images.
  for (int i = 0; i < num_images; i++) {
    for (int j = i+1; j < num_images; j++) {
      std::string image1_path    = opt.image_files[i];
      std::string image2_path    = opt.image_files[j];
      std::string match_filename = ip::match_filename(opt.out_prefix, image1_path, image2_path);

      vw_out() << "Writing: " << match_filename << std::endl;
      ip::write_binary_match_file(match_filename, cam_matches[i], cam_matches[j]);
    }
  }

}

// End map projection functions

int main(int argc, char* argv[]) {

  Options opt;
  try {
    xercesc::XMLPlatformUtils::Initialize();

    handle_arguments(argc, argv, opt);

    asp::load_cameras(opt.image_files, opt.camera_files, opt.out_prefix, opt,  
                      opt.approximate_pinhole_intrinsics,  
                      // Outputs
                      opt.stereo_session,  // may change
                      opt.single_threaded_cameras,  
                      opt.camera_models);
    
    // Prepare for computing footprints of images
    std::string dem_file_for_overlap;
    double pct_for_overlap = -1.0;
    if (opt.auto_overlap_params != "") {
      std::istringstream is(opt.auto_overlap_params);
      if (!(is >> dem_file_for_overlap >> pct_for_overlap)) 
        vw_throw(ArgumentErr() << "Could not parse correctly option --auto-overlap-params.\n");
    }

    // For when we make matches based on mapprojected images. Read mapprojected
    // images and a DEM from either command line or a list.
    std::vector<std::string> map_files;
    vw::cartography::GeoReference dem_georef;
    ImageViewRef<PixelMask<double>> interp_dem;
    if (!opt.apply_initial_transform_only) {
      
      if (!opt.mapprojected_data_list.empty()) {
        asp::read_list(opt.mapprojected_data_list, map_files);
        opt.mapprojected_data = "non-empty"; // put a token value, to make it non-empty
      } else if (opt.mapprojected_data != "") {
        std::istringstream is(opt.mapprojected_data);
        std::string file;
        while (is >> file)
          map_files.push_back(file); 
      }

      if (!opt.mapprojected_data.empty()) {
        if (opt.camera_models.size() + 1 != map_files.size()) 
          vw_throw(ArgumentErr() << "Error: Expecting as many mapprojected images as "
                   << "cameras, and also a DEM.\n");
        
        std::string dem_file = map_files.back();
        map_files.erase(map_files.end() - 1);
        
        asp::create_interp_dem(dem_file, dem_georef, interp_dem);
      }
    }
    
    // Assign the images which this instance should compute statistics for.
    std::vector<size_t> image_stats_indices;
    int num_images = opt.image_files.size();

    for (size_t i = opt.instance_index; i < num_images; i += opt.instance_count)
      image_stats_indices.push_back(i);

    // Compute statistics for the designated images (or mapprojected
    // images), and perhaps the footprints
    // TODO(oalexan1): Make this into a function
    for (size_t i = 0; i < image_stats_indices.size(); i++) {

      if (opt.apply_initial_transform_only)
        continue; // no stats need to happen

      if (opt.skip_matching || opt.clean_match_files_prefix != "" ||
          opt.match_files_prefix != "")
        continue;
      
      size_t index = image_stats_indices[i];

      // The stats need to be computed for the mapprojected image, if provided
      std::string image_path;
      if (map_files.empty()) 
        image_path = opt.image_files[index];
      else
        image_path = map_files[index];
      
      // Call a bunch of stuff to get the nodata value
      boost::shared_ptr<DiskImageResource> rsrc(vw::DiskImageResourcePtr(image_path));
      float nodata, dummy;
      asp::get_nodata_values(rsrc, rsrc, nodata, dummy);

      // Set up the image view
      DiskImageView<float> image_view(rsrc);
      ImageViewRef< PixelMask<float> > masked_image
        = create_mask_less_or_equal(image_view,  nodata);

      // Use caching function call to compute the image statistics.
      asp::gather_stats(masked_image, image_path, opt.out_prefix, image_path);

      // Compute and cache the camera footprint bbox
      if (opt.auto_overlap_params != "")
        asp::camera_bbox_with_cache(dem_file_for_overlap,
                                    opt.image_files[index], // use the original image
                                    opt.camera_models[index],  
                                    opt.out_prefix);
    }
    
    // Done computing image statistics.

    if (opt.stop_after_stats) {
      vw_out() << "Quitting after statistics computation.\n";
      xercesc::XMLPlatformUtils::Terminate();

      return 0;
    }

    // Calculate which images overlap
    if (opt.auto_overlap_params != "") {
      opt.have_overlap_list = true;
      asp::build_overlap_list_based_on_dem(opt.out_prefix,  
                                           dem_file_for_overlap, pct_for_overlap,
                                           opt.image_files, opt.camera_models,
                                           // output
                                           opt.overlap_list);
    }

    // Create the match points. Iterate through each pair of input images.

    // Load estimated camera positions if they were provided.
    std::vector<Vector3> estimated_camera_gcc;
    load_estimated_camera_positions(opt, estimated_camera_gcc);
    const bool got_est_cam_positions =
      (estimated_camera_gcc.size() == static_cast<size_t>(num_images));

    // Find interest points between all of the image pairs.
    
    // Make a list of all the image pairs to find matches for
    std::vector<std::pair<int,int> > all_pairs;
    if (!opt.apply_initial_transform_only)
      asp::determine_image_pairs(// Inputs
                                 opt.overlap_limit, opt.match_first_to_last,  
                                 opt.image_files, 
                                 got_est_cam_positions, opt.position_filter_dist,
                                 estimated_camera_gcc,
                                 opt.have_overlap_list,
                                 opt.overlap_list,
                                 // Output
                                 all_pairs);

    // Create GCP from mapprojection
    if (opt.gcp_from_mapprojected != "" && !opt.apply_initial_transform_only) {
      create_gcp_from_mapprojected_images(opt);
      return 0;
    }

    // TODO: Make this a function
    // Assign the matches which this instance should compute.
    // This is for when called from parallel_bundle_adjust.
    size_t per_instance = all_pairs.size() / opt.instance_count; // Round down
    size_t remainder    = all_pairs.size() % opt.instance_count;
    size_t start_index  = 0, this_count = 0;
    for (size_t i = 0; i <= opt.instance_index; i++) {
      this_count = per_instance;
      if (i < remainder)
        ++this_count;
      start_index += this_count;
    }
    start_index -= this_count;

    // TODO(oalexan1): The above logic is confusing. It is some
    // kind of partitioning. At least when parallel_bundle_adjust
    // is not invoked, for now check that things are as expected,
    // so all the matches are used.
    if (opt.instance_count == 1) {
      if (start_index != 0 || this_count != all_pairs.size()) 
        vw::vw_throw(vw::ArgumentErr() << "Book-keeping failure in bundle_adjust.\n");
    }
    
    std::vector<std::pair<int,int>> this_instance_pairs;
    for (size_t i=0; i<this_count; i++)
      this_instance_pairs.push_back(all_pairs[i+start_index]);

    // When using match-files-prefix or 
    // clean_match_files_prefix, form the list of match files, rather
    // than searching for them exhaustively on disk, which can get
    // very slow.
    bool external_matches = (!opt.clean_match_files_prefix.empty() ||
                             !opt.match_files_prefix.empty());
    std::set<std::string> existing_files;
    if (external_matches) {
      std::string prefix = asp::match_file_prefix(opt.clean_match_files_prefix,
                                                  opt.match_files_prefix,  
                                                  opt.out_prefix);
      vw_out() << "Computing the list of existing match files.\n";
      asp::listExistingMatchFiles(prefix, existing_files);
    }
    
    // Process the selected pairs
    for (size_t k = 0; k < this_instance_pairs.size(); k++) {

      if (opt.apply_initial_transform_only)
        continue;
      
      const int i = this_instance_pairs[k].first;
      const int j = this_instance_pairs[k].second;

      std::string const& image1_path  = opt.image_files[i];  // alias
      std::string const& image2_path  = opt.image_files[j];  // alias
      std::string const& camera1_path = opt.camera_files[i]; // alias
      std::string const& camera2_path = opt.camera_files[j]; // alias
      
      // See if perhaps to load match files from a different source
      std::string match_file 
        = asp::match_filename(opt.clean_match_files_prefix, opt.match_files_prefix,  
                              opt.out_prefix, image1_path, image2_path);

      // The external match file does not exist, don't try to load it
      if (external_matches && existing_files.find(match_file) == existing_files.end())
        continue;
     
      opt.match_files[std::make_pair(i, j)] = match_file;

      // If we skip matching (which is the case, among other situations, when
      // using external matches), there's no point in checking if the match
      // files are recent.
      bool inputs_changed = false;
      if (!opt.skip_matching) {
        inputs_changed = (!asp::is_latest_timestamp(match_file,
                                                    image1_path,  image2_path,
                                                    camera1_path, camera2_path));

        // We make an exception and not rebuild if explicitly asked
        if (asp::stereo_settings().force_reuse_match_files &&
            boost::filesystem::exists(match_file))
          inputs_changed = false;
      }
      
      if (!inputs_changed) {
        vw_out() << "\t--> Using cached match file: " << match_file << "\n";
        continue;
      }

      // Read no-data
      boost::shared_ptr<DiskImageResource>
        rsrc1(vw::DiskImageResourcePtr(image1_path)),
        rsrc2(vw::DiskImageResourcePtr(image2_path));
      if ((rsrc1->channels() > 1) || (rsrc2->channels() > 1))
        vw_throw(ArgumentErr() << "Error: Input images can only have a single channel!\n\n");
      float nodata1, nodata2;
      asp::get_nodata_values(rsrc1, rsrc2, nodata1, nodata2);
      
      // Set up the stereo session
      SessionPtr session(asp::StereoSessionFactory::create(opt.stereo_session, // may change
                                                           opt, image1_path,  image2_path,
                                                           camera1_path, camera2_path,
                                                           opt.out_prefix));


      // Find matches between image pairs. This may not always succeed.
      try{

        if (opt.mapprojected_data == "") 
          ba_match_ip(opt, session, image1_path, image2_path,
                      opt.camera_models[i].get(),
                      opt.camera_models[j].get(),
                      match_file);

        else
          matches_from_mapproj_images(i, j, opt, session, map_files, dem_georef, interp_dem,  
                                      match_file);

        // Compute the coverage fraction
        std::vector<ip::InterestPoint> ip1, ip2;
        ip::read_binary_match_file(match_file, ip1, ip2);
        int right_ip_width = rsrc1->cols() *
                              static_cast<double>(100-opt.ip_edge_buffer_percent)/100.0;
        Vector2i ip_size(right_ip_width, rsrc1->rows());
        double ip_coverage = asp::calc_ip_coverage_fraction(ip2, ip_size);
        vw_out() << "IP coverage fraction = " << ip_coverage << std::endl;
      } catch (const std::exception& e){
        vw_out() << "Could not find interest points between images "
                  << opt.image_files[i] << " and " << opt.image_files[j] << std::endl;
        vw_out(WarningMessage) << e.what() << std::endl;
      } //End try/catch
    } // End loop through all input image pairs

    if (opt.stop_after_matching){
      vw_out() << "Quitting after matches computation.\n";
      return 0;
    }

    // All the work happens here! It also writes out the results.
    do_ba_ceres(opt, estimated_camera_gcc);

    xercesc::XMLPlatformUtils::Terminate();

  } ASP_STANDARD_CATCHES;
}
