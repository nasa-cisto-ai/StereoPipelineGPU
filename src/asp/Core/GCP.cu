// __BEGIN_LICENSE__
//  Copyright (c) 2006-2013, United States Government as represented by the
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


#include <string>
#include <vector>

#include <vw/FileIO/DiskImageView.h>
#include <vw/Image/Interpolation.h>
#include <vw/Cartography/GeoReference.h>
#include <asp/Core/GCP.h>

namespace asp {

// Write a GCP file. Can throw exceptions.
void writeGCP(std::vector<std::string> const& image_files,
              std::string const& gcp_file,
              std::string const& dem_file,
              std::string const& output_prefix,
              asp::MatchList const& matchlist) {
  
  using namespace vw;
  
  // Load a georeference to use for the GCPs from the last image
  vw::cartography::GeoReference georef_image, georef_dem;
  const size_t GEOREF_INDEX = image_files.size() - 1;
  const std::string georef_image_file = image_files[GEOREF_INDEX];
  bool has_georef = vw::cartography::read_georeference(georef_image, georef_image_file);
  // todo(oalexan1): Throw an exception here, then catch it and pop up a message box.
  if (!has_georef)
    vw::vw_throw(vw::ArgumentErr() << "Could not load a valid georeference to use for "
		 << "ground control points in file: " << georef_image_file << ".\n");

  vw::vw_out() << "Loaded georef from file " << georef_image_file << std::endl;
  
  // Init the DEM to use for height interpolation
  boost::shared_ptr<vw::DiskImageResource> dem_rsrc(DiskImageResourcePtr(dem_file));
  vw::DiskImageView<float> dem_disk_image(dem_file);
  vw::ImageViewRef<vw::PixelMask<float>> raw_dem;
  float nodata_val = -std::numeric_limits<float>::max();
  if (dem_rsrc->has_nodata_read()) {
    nodata_val = dem_rsrc->nodata_read();
    raw_dem = vw::create_mask_less_or_equal(dem_disk_image, nodata_val);
  } else {
    raw_dem = vw::pixel_cast<vw::PixelMask<float>>(dem_disk_image);
  }
  vw::PixelMask<float> fill_val;
  fill_val[0] = -99999;
  fill_val.invalidate();
  vw::ImageViewRef<vw::PixelMask<float>> interp_dem
    = vw::interpolate(raw_dem,
                  vw::BilinearInterpolation(),
                  vw::ValueEdgeExtension<vw::PixelMask<float>>(fill_val));
  
  // Load the georef from the DEM
  has_georef = vw::cartography::read_georeference(georef_dem, dem_file);
  if (!has_georef)
    vw::vw_throw(vw::ArgumentErr() << "Could not load a valid georeference from dem file: "
                 << dem_file << ".\n");
  
  vw_out() << "Loaded georef from dem file " << dem_file << std::endl;
  
  BBox2 image_bb = bounding_box(interp_dem);
  vw_out() << "Writing: " << gcp_file << "\n";
  std::ofstream output_handle(gcp_file.c_str());
  output_handle << std::setprecision(17);
  size_t num_pts_skipped = 0, num_pts_used = 0;
  const size_t num_ips    = matchlist.getNumPoints();
  for (size_t p = 0; p < num_ips; p++) { // Loop through IPs
    
    // Compute the GDC coordinate of the point
    ip::InterestPoint ip = matchlist.getPoint(GEOREF_INDEX, p);
    Vector2 lonlat    = georef_image.pixel_to_lonlat(Vector2(ip.x, ip.y));
    Vector2 dem_pixel = georef_dem.lonlat_to_pixel(lonlat);
    PixelMask<float> height = interp_dem(dem_pixel[0], dem_pixel[1])[0];
    
    // We make a separate bounding box check because the ValueEdgeExtension
    //  functionality may not work properly!
    if ( (!image_bb.contains(dem_pixel)) || (!is_valid(height)) ) {
      vw_out() << "Warning: Skipped IP # " << p
               << " because it does not fall on the DEM.\n";
      ++num_pts_skipped;
      continue; // Skip locations which do not fall on the DEM
    }
    
    // Write the per-point information
    output_handle << num_pts_used; // The ground control point ID
    bool write_ecef = false;
    // TODO(oalexan1): It can be convenient to export GCP in ECEF, for software
    // which does not know about projections. Could be an option.
    if (!write_ecef) {
      // Write lat, lon, height
      output_handle << ", " << lonlat[1] << ", " << lonlat[0] << ", " << height[0];
    } else {
      // Write x, y, z
      vw::Vector3 P(lonlat[0], lonlat[1], height[0]);
      P = georef_dem.datum().geodetic_to_cartesian(P);
      output_handle << ", " << P[0] << ' ' << P[1] << ' ' << P[2];
    }
    
    // Write sigma values on the same line
    output_handle << ", " << 1 << ", " << 1 << ", " << 1; 
    
    // Write the per-image information
    // The last image is the reference image, so we skip it when saving GCPs
    size_t num_images = image_files.size();
    size_t num_images_to_save = num_images - 1; 
    for (size_t i = 0; i < num_images_to_save; i++) {
      // Add this IP to the current line
      ip::InterestPoint ip = matchlist.getPoint(i, p);
      output_handle << ", " << image_files[i];
      output_handle << ", " << ip.x << ", " << ip.y; // IP location in image
      output_handle << ", " << 1 << ", " << 1; // Sigma values
    } // End loop through IP sets
    output_handle << std::endl; // Finish the line
    ++num_pts_used;
  } // End loop through IPs
  
  output_handle.close();

  return;
}

} // namespace asp
