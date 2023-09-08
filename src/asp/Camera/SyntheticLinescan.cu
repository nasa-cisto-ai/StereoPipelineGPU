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

#include <asp/Core/Common.h>
#include <asp/Core/CameraTransforms.h>
#include <asp/Camera/CsmModel.h>
#include <asp/Camera/SyntheticLinescan.h>
#include <asp/Camera/SatSim.h>

#include <usgscsm/UsgsAstroLsSensorModel.h>

#include <vw/Camera/PinholeModel.h>
#include <vw/Image/ImageViewRef.h>
#include <vw/Cartography/CameraBBox.h>
#include <vw/Math/Functors.h>
#include <vw/Core/Stopwatch.h>

namespace asp {

// Populate the CSM model with the given camera positions and orientations. Note
// that opt.num_cameras is the number of cameras within the desired orbital segment
// of length orbit_len. We will have extra cameras beyond that segment to make it 
// easy to interpolate the camera position and orientation at any time and also to 
// solve for jitter. We can have -opt.num_cams/2 <= i < 2*opt.num_cams - opt.num_cams/2. 
// When 0 <= i < opt.num_cams, we are within the orbital segment.
void populateSyntheticLinescan(SatSimOptions const& opt, 
                      double orbit_len, 
                      vw::cartography::GeoReference const & georef,    
                      std::map<int, vw::Vector3>    const & positions,
                      std::map<int, vw::Matrix3x3>  const & cam2world,
                      // Outputs
                      asp::CsmModel & model) {

  // Must have as many positions as orientations
  if (positions.size() != cam2world.size())
    vw_throw(vw::ArgumentErr() << "Expecting as many positions as orientations.\n");

  // Do not use a precision below 1.0-e8 as then the linescan model will return junk.
  model.m_desired_precision = asp::DEFAULT_CSM_DESIRED_PRECISISON;
  model.m_semi_major_axis = georef.datum().semi_major_axis();
  model.m_semi_minor_axis = georef.datum().semi_minor_axis();

  // Create the linescan model. Memory is managed by m_gm_model.
  model.m_gm_model.reset(new UsgsAstroLsSensorModel);
  UsgsAstroLsSensorModel* ls_model
    = dynamic_cast<UsgsAstroLsSensorModel*>(model.m_gm_model.get());
  if (ls_model == NULL)
    vw::vw_throw(vw::ArgumentErr() << "Invalid initialization of the linescan model.\n");

  // This performs many initializations apart from the above
  ls_model->reset();

  // Override some initializations
  ls_model->m_nSamples         = opt.image_size[0]; 
  ls_model->m_nLines           = opt.image_size[1];
  ls_model->m_platformFlag     = 1; // Use 1, for order 8 Lagrange interpolation
  ls_model->m_minElevation     = -10000.0; // -10 km
  ls_model->m_maxElevation     =  10000.0; //  10 km
  ls_model->m_focalLength      = opt.focal_length;
  ls_model->m_zDirection       = 1.0;
  ls_model->m_halfSwath        = 1.0;
  ls_model->m_sensorIdentifier = "SyntheticLinescan";
  ls_model->m_majorAxis        = model.m_semi_major_axis;
  ls_model->m_minorAxis        = model.m_semi_minor_axis;
  
  // The choices below are copied from the DigitalGlobe CSM linescan model.
  // Better to keep same convention than dig deep inside UsAstroLsSensorModel.
  // Also keep in mind that a CSM pixel has extra 0.5 added to it.
  vw::Vector2 detector_origin;
  detector_origin[0]                 = -opt.optical_center[0]; 
  detector_origin[1]                 = 0.0;
  ls_model->m_iTransL[0]             = 0.0;  
  ls_model->m_iTransL[1]             = 0.0;
  ls_model->m_iTransL[2]             = 1.0;
  ls_model->m_iTransS[0]             = 0.0;
  ls_model->m_iTransS[1]             = 1.0;
  ls_model->m_iTransS[2]             = 0.0;
  ls_model->m_detectorLineOrigin     = 0.0;
  ls_model->m_detectorSampleOrigin   = 0.0;
  ls_model->m_detectorLineSumming    = 1.0;
  ls_model->m_startingDetectorLine   = detector_origin[1];
  ls_model->m_detectorSampleSumming  = 1.0;
  ls_model->m_startingDetectorSample = (detector_origin[0] - 0.5);

  // Set the time. The first image line time is 0. The last image line time
  // will depend on distance traveled and speed.
  double beg_t = 0.0;
  double end_t = orbit_len / opt.velocity;
  double dt = (end_t - beg_t) / (opt.image_size[1] - 1.0);
  ls_model->m_intTimeLines.push_back(1.0); // to offset CSM's quirky 0.5 additions in places
  ls_model->m_intTimeStartTimes.push_back(beg_t);
  ls_model->m_intTimes.push_back(dt);

  // Positions and velocities. Note how, as above, there are more positions than
  // opt.num_cameras as they extend beyond orbital segment. So care is needed
  // below. Time is 0 when we reach the first image line, and it is end_t at the
  // last line. Positions before that have negative time. Time at position with
  // index i is m_t0Ephem + i*m_dtEphem, if index 0 is for the earliest postion,
  // but that is way before the orbital segment starting point which is the
  // first image line. We can have -opt.num_cams/2 <= pos_it->first <
  // 2*opt.num_cams - opt.num_cams/2.
  int beg_pos_index = positions.begin()->first; // normally equals -opt.num_cameras/2
  if (beg_pos_index > 0)
    vw::vw_throw(vw::ArgumentErr() << "First position index must be non-positive.\n");
  ls_model->m_numPositions = 3 * positions.size(); // concatenate all coordinates
  ls_model->m_dtEphem = (end_t - beg_t) / (opt.num_cameras - 1.0); // care here
  ls_model->m_t0Ephem = beg_t + beg_pos_index * ls_model->m_dtEphem; // care here

  ls_model->m_positions.resize(ls_model->m_numPositions);
  ls_model->m_velocities.resize(ls_model->m_numPositions);
  for (auto pos_it = positions.begin(); pos_it != positions.end(); pos_it++) {
    int index = pos_it->first - beg_pos_index; // so we can start at 0
    auto ctr = pos_it->second;
    for (int coord = 0; coord < 3; coord++) {
      ls_model->m_positions [3*index + coord] = ctr[coord];
      ls_model->m_velocities[3*index + coord] = 0.0; // should not be used
    }
  }

  // Orientations. Care with defining dt as above.
  int beg_quat_index = cam2world.begin()->first; // normally equals -opt.num_cameras/2
  if (beg_quat_index > 0)
    vw::vw_throw(vw::ArgumentErr() << "First orientation index must be non-positive.\n");
  if (beg_pos_index != beg_quat_index)
    vw::vw_throw(vw::ArgumentErr() 
      << "First position index must equal first orientation index.\n");
      
  ls_model->m_numQuaternions = 4 * cam2world.size();
  ls_model->m_dtQuat = (end_t - beg_t) / (opt.num_cameras - 1.0);
  ls_model->m_t0Quat = beg_t + beg_quat_index * ls_model->m_dtQuat;

  ls_model->m_quaternions.resize(ls_model->m_numQuaternions);
  for (auto quat_it = cam2world.begin(); quat_it != cam2world.end(); quat_it++) {
    int index = quat_it->first - beg_quat_index; // so we can start at 0

    // Find the quaternion at this index.
    auto c2w = quat_it->second;
    double x, y, z, w;
    asp::matrixToQuaternion(c2w, x, y, z, w);

    // Note how we store the quaternions in the order x, y, z, w, not w, x, y, z.
    int coord = 0;
    ls_model->m_quaternions[4*index + coord] = x; coord++;
    ls_model->m_quaternions[4*index + coord] = y; coord++;
    ls_model->m_quaternions[4*index + coord] = z; coord++;
    ls_model->m_quaternions[4*index + coord] = w; coord++;
  }

  // Re-creating the model from the state forces some operations to
  // take place which are inaccessible otherwise.
  std::string modelState = ls_model->getModelState();
  ls_model->replaceModelState(modelState);
}

// Allow finding the time at any line, even negative ones. Here a
// simple slope-intercept formula is used rather than a table. 
// This was a temporary function used for debugging
// double get_time_at_line(double line) const {
//     csm::ImageCoord csm_pix;
//     asp::toCsmPixel(vw::Vector2(0, line), csm_pix);
//     return ls_model->getImageTime(csm_pix);
// }

// The pointing vector in sensor coordinates, before applying cam2world. This
// is for testing purposes. Normally CSM takes care of this internally.
// This was a temporary function used for debugging
// vw::Vector3 get_local_pixel_to_vector(vw::Vector2 const& pix) const {

//   vw::Vector3 result(pix[0] + detector_origin[0], 
//                       detector_origin[1], 
//                       ls_model->m_focalLength);
//   // Make the direction have unit length
//   result = normalize(result);
//   return result;
// }

// Compare the camera center and direction with pinhole. A very useful
// test.
void PinLinescanTest(SatSimOptions                const & opt, 
                     asp::CsmModel                const & ls_cam,
                     std::map<int, vw::Vector3>   const & positions,
                     std::map<int, vw::Matrix3x3> const & cam2world) {
                        
  for (int i = 0; i < int(positions.size()); i++) {

    auto pin_cam 
      = vw::camera::PinholeModel(asp::mapVal(positions, i),
                                 asp::mapVal(cam2world, i),
                                 opt.focal_length, opt.focal_length,
                                 opt.optical_center[0], opt.optical_center[1]);
  
    double line = (opt.image_size[1] - 1.0) * i / std::max((positions.size() - 1.0), 1.0);
  
    // Need care here
    vw::Vector2 pin_pix(opt.optical_center[0], opt.optical_center[1]);
    vw::Vector2 ls_pix (opt.optical_center[0], line);

    // The differences below must be 0
    vw::Vector3 ls_ctr  = ls_cam.camera_center(ls_pix);
    vw::Vector3 pin_ctr = pin_cam.camera_center(pin_pix);
    std::cout << "ls ctr and and pin - ls ctr diff: " << ls_ctr << " "
              << norm_2(pin_ctr - ls_ctr) << std::endl;

    vw::Vector3 ls_dir = ls_cam.pixel_to_vector(ls_pix);
    vw::Vector3 pin_dir = pin_cam.pixel_to_vector(pin_pix);
    std::cout << "ls dir and pin - ls dir diff: " << ls_dir << " "
              << norm_2(pin_dir - ls_dir) << std::endl;
  }
}

// Wrapper for logic to intersect DEM with ground. The xyz provided on input serves
// as initial guess and gets updated on output if the intersection succeeds. Return
// true on success.
bool intersectDemWithRay(SatSimOptions const& opt,
                         vw::cartography::GeoReference const& dem_georef,vw::ImageViewRef<vw::PixelMask<float>> dem,
                         vw::Vector3 const& cam_ctr, 
                         vw::Vector3 const& cam_dir,
                         double height_guess,
                         // Output
                         vw::Vector3 & xyz) {

    // Find the intersection of this ray with the ground
    bool treat_nodata_as_zero = false;
    bool has_intersection = false;
    double max_abs_tol = std::min(opt.dem_height_error_tol, 1e-14);
    double max_rel_tol = max_abs_tol;
    int num_max_iter = 100;

    vw::Vector3 local_xyz 
      = vw::cartography::camera_pixel_to_dem_xyz
        (cam_ctr, cam_dir, dem, dem_georef, treat_nodata_as_zero, has_intersection, 
        // Below we use a prudent approach. Try to make the solver work
        // hard. It is not clear if this is needed.
        std::min(opt.dem_height_error_tol, 1e-8),
        max_abs_tol, max_rel_tol, 
        num_max_iter, xyz, height_guess);

    if (!has_intersection)
      return false;

    // Update xyz with produced value if we succeeded
    xyz = local_xyz;
    return true;
}

// Estimate pixel aspect ratio (width / height) of a pixel on the ground
double pixelAspectRatio(SatSimOptions                 const & opt,     
                        vw::cartography::GeoReference const & dem_georef,
                        asp::CsmModel                 const & ls_cam,
                        vw::ImageViewRef<vw::PixelMask<float>>  dem,  
                        double height_guess) {

  // Put here a stop watch
  //vw::Stopwatch sw;
  //sw.start();

  // We checked that the image width and height is at least 2 pixels. That is
  // needed to properly create the CSM model. Now do some samples to see how the
  // pixel width and height are on the ground. Use a small set of samples. Should be good
  // enough. Note how we go a little beyond each sample, while still not exceeding
  // the designed image size. 
  double samp_x = (opt.image_size[0] - 1.0) / 10.0;
  double samp_y = (opt.image_size[1] - 1.0) / 10.0;

  std::vector<double> ratios; 
  vw::Vector3 xyz(0, 0, 0); // intersection with DEM, will be updated below
  
  for (double x = 0; x < opt.image_size[0] - 1.0; x += samp_x) {
    for (double y = 0; y < opt.image_size[1] - 1.0; y += samp_y) {

      // Find the intersection of the ray from this pixel with the ground
      vw::Vector2 pix(x, y);
      vw::Vector3 ctr = ls_cam.camera_center(pix);
      vw::Vector3 dir = ls_cam.pixel_to_vector(pix);
      bool ans = intersectDemWithRay(opt, dem_georef, dem, ctr, dir, 
         height_guess, xyz);
      if (!ans) 
        continue;
      vw::Vector3 P0 = xyz;

      // Add a little to the pixel, but stay within the image bounds
      double dx = std::min(samp_x, 0.5);
      double dy = std::min(samp_y, 0.5);

      // See pixel width on the ground
      pix = vw::Vector2(x + dx, y);
      ctr = ls_cam.camera_center(pix);
      dir = ls_cam.pixel_to_vector(pix);
      ans = intersectDemWithRay(opt, dem_georef, dem, ctr, dir, 
         height_guess, xyz);
      if (!ans) 
        continue;
      vw::Vector3 Px = xyz;

      // See pixel height on the ground
      pix = vw::Vector2(x, y + dy);
      ctr = ls_cam.camera_center(pix);
      dir = ls_cam.pixel_to_vector(pix);
      ans = intersectDemWithRay(opt, dem_georef, dem, ctr, dir, 
         height_guess, xyz);
      if (!ans)
        continue;
      vw::Vector3 Py = xyz;

      double ratio = norm_2(Px - P0) / norm_2(Py - P0);
      if (std::isnan(ratio) || std::isinf(ratio) || ratio <= 0.0)
        continue;
      ratios.push_back(ratio);
    }
  }

  if (ratios.empty())
    vw::vw_throw(vw::ArgumentErr() << "No valid samples found to compute "
             << "the pixel width and height on the ground.\n");

  double ratio = vw::math::destructive_median(ratios);

  //sw.stop();
  //std::cout << "Time to compute pixel aspect ratio: " << sw.elapsed_seconds() << std::endl;

  return ratio;
}

// Create and save a linescan camera with given camera positions and orientations.
// There will be just one of them, as all poses are part of the same linescan camera.
void genLinescanCameras(double                                orbit_len, 
                        vw::cartography::GeoReference const & dem_georef,
                        vw::ImageViewRef<vw::PixelMask<float>> dem,  
                        std::map<int, vw::Vector3>    const & positions,
                        std::map<int, vw::Matrix3x3>  const & cam2world,
                        std::map<int, vw::Matrix3x3>  const & cam2world_no_jitter,
                        std::map<int, vw::Matrix3x3>  const & ref_cam2world,
                        double                                height_guess,
                        // Outputs
                        SatSimOptions                         & opt, 
                        std::vector<std::string>              & cam_names,
                        std::vector<vw::CamPtr>               & cams) {

  // Sanity checks
  if (cam2world.size() != positions.size() || cam2world_no_jitter.size() != positions.size())
    vw::vw_throw(vw::ArgumentErr() << "Expecting as many camera orientations as positions.\n");

  // Initialize the outputs
  cam_names.clear();
  cams.clear();

  // Create the camera. Will be later owned by a smart pointer.
  asp::CsmModel * ls_cam = new asp::CsmModel;

  // If creating square pixels, must use the camera without jitter to estimate
  // the image height. Otherwise the image height produced from the camera with
  // jitter will be inconsistent with the one without jitter. This is a bugfix. 
  if (!opt.square_pixels) 
    populateSyntheticLinescan(opt, orbit_len, dem_georef, positions, cam2world, 
      *ls_cam); // output 
  else
    populateSyntheticLinescan(opt, orbit_len, dem_georef, positions, cam2world_no_jitter,   
      *ls_cam); // output

  // Sanity check (very useful)
  // PinLinescanTest(opt, *ls_cam, positions, cam2world);

  if (opt.square_pixels) {
    // Find the pixel aspect ratio on the ground (x/y)
    vw::vw_out() << "Adjusting image height from " << opt.image_size[1] << " to ";
    double ratio = pixelAspectRatio(opt, dem_georef, *ls_cam, dem, height_guess);
    // Adjust the image height to make the pixels square
    opt.image_size[1] = std::max(round(opt.image_size[1] / ratio), 2.0);
    vw::vw_out() << opt.image_size[1] << " pixels, to make the ground "
                 << "projection of an image pixel be roughly square.\n";

    // Recreate the camera with this aspect ratio. This time potentially use the 
    // camera with jitter. 
    populateSyntheticLinescan(opt, orbit_len, dem_georef, positions, cam2world, *ls_cam); 
    // Sanity check (very useful for testing, the new ratio must be close to 1.0)
    // ratio = pixelAspectRatio(opt, dem_georef, *ls_cam, dem, height_guess);
  }
  std::string filename = opt.out_prefix + ".json";
  ls_cam->saveState(filename);

  if (opt.save_ref_cams) {
      asp::CsmModel ref_cam;
      populateSyntheticLinescan(opt, orbit_len, dem_georef, positions, ref_cam2world,
        ref_cam); // output
    std::string ref_filename = opt.out_prefix + "-ref.json";
    ref_cam.saveState(ref_filename);
  }

  // Save the camera name and smart pointer to camera
  cam_names.push_back(filename);
  cams.push_back(vw::CamPtr(ls_cam));

  return;
}

// A function to read Linescan cameras from disk. There will
// be just one of them, but same convention is kept as for Pinhole
// where there is many of them. Note that the camera is created as of CSM type,
// rather than asp::CsmModel type. This is not important as we will
// abstract it right away to the base class.
void readLinescanCameras(SatSimOptions const& opt, 
    std::vector<std::string> & cam_names,
    std::vector<vw::CamPtr> & cams) {

  // Read the camera names
  vw::vw_out() << "Reading: " << opt.camera_list << std::endl;
  asp::read_list(opt.camera_list, cam_names);

  // Sanity checks
  if (cam_names.empty())
    vw::vw_throw(vw::ArgumentErr() << "No cameras were found.\n");
  if (cam_names.size() != 1)
    vw::vw_throw(vw::ArgumentErr() << "Only one linescan camera is expected.\n");

  cams.resize(cam_names.size());
  for (int i = 0; i < int(cam_names.size()); i++)
    cams[i] = vw::CamPtr(new asp::CsmModel(cam_names[i]));

  return;
}

} // end namespace asp

