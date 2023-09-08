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

#include <asp/Gotcha/CBatchProc.h>
#include <asp/Gotcha/CDensifyParam.h>
#include <asp/Gotcha/CDensify.h>

#include <boost/filesystem.hpp>

namespace fs = boost::filesystem;
using namespace vw;
using namespace cv;
using namespace std;

namespace gotcha {
  
// Convert a float image from ASP format to an OpenCV float image
// and vice-versa. Note that ASP stores an image as col, row.
  
void aspMatToCvMat(vw::ImageView<float> const& in, cv::Mat & out) {
  out = cv::Mat::zeros(in.rows(), in.cols(), CV_32F);
  for (int row = 0; row < out.rows; row++) {
    for (int col = 0; col < out.cols; col++) {
      out.at<float>(row, col) = in(col, row);
    }
  }
}

void cvMatToAspMat(cv::Mat const& in, vw::ImageView<float> & out) {
  out.set_size(in.cols, in.rows); 
  for (int row = 0; row < in.rows; row++) {
    for (int col = 0; col < in.cols; col++) {
      out(col, row) = in.at<float>(row, col);
    }
  }
}
  
CBatchProc::CBatchProc(std::string          const & strMetaFile,
                       vw::ImageView<float> const & imgL,
                       vw::ImageView<float> const & imgR, 
                       vw::ImageView<float> const & input_dispX,
                       vw::ImageView<float> const & input_dispY) {

  // Sanity checks
  if (bounding_box(imgL)        != bounding_box(imgR) ||
      bounding_box(input_dispX) != bounding_box(imgR) ||
      bounding_box(input_dispY) != bounding_box(imgR)) 
    vw_throw(ArgumentErr() << "Not all inputs have the same dimensions.");
  
  // initialize
  m_strMetaFile = strMetaFile;
  
#if 0
  m_strImgL = strLeftImagePath;
  m_strImgR = strRightImagePath;
  m_strDispX = strDisparityX;
  m_strDispY = strDisparityY;
  m_strOutPath = strOutputPrefix;
#endif
  
  // Convert the inputs to cv::Mat, which is what Gotcha prefers
  aspMatToCvMat(imgL, m_imgL);
  aspMatToCvMat(imgR, m_imgR);
  aspMatToCvMat(input_dispX, m_input_dispX);
  aspMatToCvMat(input_dispY, m_input_dispY);
  
  if (!validateProjParam()){
    std::cerr << "ERROR: The project input files cannot be validated" << std::endl;
    exit(1);
  }
  if (!validateProjInputs()){
    std::cerr << "ERROR: The project input files not in correct format" << std::endl;
    exit(1);
  }
}

CBatchProc::~CBatchProc() {
}

bool CBatchProc::validateProjParam() {
  bool bRes = true;

#if 0
  // image file existence
  if (!fs::exists(m_strImgL)){
    std::cerr << "ERROR: Left image file does not exist." << std::endl;
    bRes = false;
  }

  if (!fs::exists(m_strImgR)){
    std::cerr << "ERROR: Right image file does not exist." << std::endl;
    bRes = false;
  }

  // These are passed in-memory now
  if (!fs::exists(m_strDispX)){
    std::cerr << "Gotcha on given disparity map. ERROR: X disparity file does not exist." << std::endl;
    bRes = false;
  }

  if (!fs::exists(m_strDispY)){
    std::cerr << "Gotcha on given disparity map. ERROR: Y disparity file does not exist." << std::endl;
    bRes = false;
  }
#endif
  
  return bRes;
}

bool CBatchProc::validateProjInputs() {
  bool bRes = true;

  //m_input_dispX = imread(m_strDispX, CV_LOAD_IMAGE_ANYDEPTH);
  //m_input_dispY = imread(m_strDispY, CV_LOAD_IMAGE_ANYDEPTH);
  if ((m_input_dispX.depth()!=2 && m_input_dispX.depth()!=5)|| (m_input_dispY.depth()!=2 && m_input_dispY.depth()!=5)){
    bRes = false;
    std::cerr << "Gotcha on given disparity map. ERROR: Input x/y disparity map not in 16bit unsigned integer or 32bit floating point" << std::endl;
  }
  if (m_input_dispX.channels()!=1 || m_input_dispY.channels()!=1){
    bRes = false;
    std::cerr << "Gotcha on given disparity map. ERROR: Please take single channel image as input x/y disparity map" << std::endl;
  }

  //std::cout << "Generating bad pixel/gap mask file." << std::endl;
  generateMask();

  //std::cout << "Reading mask: " << m_strMask << std::endl;
  //Mat Mask = imread(m_strMask, CV_LOAD_IMAGE_ANYDEPTH);
  if (m_Mask.depth()!=0 || m_Mask.channels()!=1){
    bRes = false;
    std::cerr << "ERROR: Input mask file not in 8 bit single channel unsigned int format" << std::endl;
  }
  return bRes;
}

void CBatchProc::doBatchProcessing(vw::ImageView<float> & output_dispX,
                                   vw::ImageView<float> & output_dispY) {

  //std::cout << "Starting processing now..." << std::endl
  //     << "================================" << std::endl << std::endl;

  std::vector<CTiePt> vecTPs;
  generateTPFile(vecTPs);
  refinement(vecTPs, output_dispX, output_dispY);

  //std::cout << "Process completed" << std::endl;
  //std::cout << std::endl;
  //std::cout << "================================" << std::endl << std::endl;
}

void CBatchProc::generateMask() {
  // These are kept in memory now, no need to read them from disk
#if 0
  string strMask = "-GM.tif";
  m_strMask = m_strOutPath + strMask;
  m_input_dispX = imread(m_strDispX, CV_LOAD_IMAGE_ANYDEPTH);
  m_input_dispY = imread(m_strDispY, CV_LOAD_IMAGE_ANYDEPTH);
#endif
  
  m_Mask = Mat::zeros(m_input_dispX.size(), CV_8UC1);

  if (m_input_dispX.depth()==2 && m_input_dispY.depth()==2){
    for (int i=0; i<m_Mask.rows; i++){
      for (int j=0; j<m_Mask.cols; j++){
        if (m_input_dispX.at<ushort>(i,j)==65535 || m_input_dispY.at<ushort>(i,j)==65535)
          m_Mask.at<uchar>(i,j)=1;
      }
    }

    //std::cout << "Writing mask: " << m_strMask << std::endl;
    //imwrite(m_strMask, Mask);
  }

  else if (m_input_dispX.depth()==5 && m_input_dispY.depth()==5){
    int numBadpixel = 0;
    for (int i=0; i<m_Mask.rows; i++){
      for (int j=0; j<m_Mask.cols; j++){
        if (m_input_dispX.at<float>(i,j)==0.0) { //Nodata value of ASP disparity is 0.
          m_Mask.at<uchar>(i,j)=1;
          numBadpixel+=1;
        }
      }
    }
    //std::cout << "GAP Pixels masked: " << numBadpixel << std::endl;
    //std::cout << "Writing mask: " << m_strMask << std::endl;
    //imwrite(m_strMask, Mask);
  }

}

void CBatchProc::generateTPFile(std::vector<CTiePt> & vecTPs) {

  // Wipe the output
  vecTPs.clear();

  cv::Mat dispX, dispY;

  m_input_dispX.copyTo(dispX);
  m_input_dispY.copyTo(dispY);

  // Turn this logic off, as the data is kept in memory
#if 0
  dispX = imread(m_strDispX, CV_LOAD_IMAGE_ANYDEPTH);
  dispY = imread(m_strDispY, CV_LOAD_IMAGE_ANYDEPTH);
  std::cout << "Reading mask: " << m_strMask << std::endl;
  Mat Mask = imread(m_strMask, CV_LOAD_IMAGE_ANYDEPTH);
  Mask.convertTo(Mask, CV_8UC1);
#endif
  
  //string strTPFile = "-TP.txt";
  //m_strTPFile = m_strOutPath + strTPFile;

  if (dispX.depth()==2 && dispY.depth()==2){
    dispX.convertTo(dispX, CV_16UC1);
    dispY.convertTo(dispY, CV_16UC1);
    for (int i=0; i<dispX.rows; i++){
      for (int j=0; j<dispX.cols; j++){
        if (m_Mask.at<uchar>(i,j)==1){
          dispX.at<ushort>(i,j)=65535;
          dispY.at<ushort>(i,j)=65535;
        }
      }
    }
  }

  else if (dispX.depth()==5 && dispY.depth()==5){
    dispX.convertTo(dispX, CV_32FC1);
    dispY.convertTo(dispY, CV_32FC1);
    for (int i=0; i<dispX.rows; i++){
      for (int j=0; j<dispX.cols; j++){
        if (m_Mask.at<uchar>(i,j)==1){
          dispX.at<float>(i,j)= 0.0;
          dispY.at<float>(i,j)= 0.0;
        }
      }
    }
  }


  if (dispX.depth()==2 && dispY.depth()==2){
    Mat dispX_tmp(dispX.size(),CV_16UC1);
    Mat dispY_tmp(dispY.size(),CV_16UC1);
    dispX.copyTo(dispX_tmp);
    dispY.copyTo(dispY_tmp);
    for (int i=1; i<dispX.rows-1; i++){
      for (int j=1; j<dispX.cols-1; j++){
        if (dispX.at<ushort>(i-1,j-1)!=65535 && dispX.at<ushort>(i-1,j)!=65535 && dispX.at<ushort>(i-1,j+1)!=65535 && dispX.at<ushort>(i,j-1)!=65535 &&
            dispX.at<ushort>(i,j+1)!=65535 && dispX.at<ushort>(i+1,j-1)!=65535 && dispX.at<ushort>(i+1,j)!=65535 && dispX.at<ushort>(i+1,j+1)!=65535 &&
            dispY.at<ushort>(i-1,j-1)!=65535 && dispY.at<ushort>(i-1,j)!=65535 && dispY.at<ushort>(i-1,j+1)!=65535 && dispY.at<ushort>(i,j-1)!=65535 &&
            dispY.at<ushort>(i,j+1)!=65535 && dispY.at<ushort>(i+1,j-1)!=65535 && dispY.at<ushort>(i+1,j)!=65535 && dispY.at<ushort>(i+1,j+1)!=65535){
          dispX_tmp.at<ushort>(i,j)=65535;
          dispY_tmp.at<ushort>(i,j)=65535;
        }
      }
    }
    dispX_tmp.copyTo(dispX);
    dispY_tmp.copyTo(dispY);
  }

  else if (dispX.depth()==5 && dispY.depth()==5){
    Mat dispX_tmp(dispX.size(),CV_32FC1);
    Mat dispY_tmp(dispY.size(),CV_32FC1);
    Mat dispX_tmp2(dispX.size(),CV_32FC1);
    Mat dispY_tmp2(dispY.size(),CV_32FC1);

    // Only leave the gap border pixels to speed-up the process.
    // Should be cancelled if use sGotcha

    dispX.copyTo(dispX_tmp);
    dispY.copyTo(dispY_tmp);
    for (int i=1; i<dispX.rows-1; i++){
      for (int j=1; j<dispX.cols-1; j++){
        if (dispX.at<float>(i-1,j-1)!=0.0 && dispX.at<float>(i-1,j)!=0.0 && dispX.at<float>(i-1,j+1)!=0.0 && dispX.at<float>(i,j-1)!=0.0 &&
            dispX.at<float>(i,j+1)!=0.0 && dispX.at<float>(i+1,j-1)!=0.0 && dispX.at<float>(i+1,j)!=0.0 && dispX.at<float>(i+1,j+1)!=0.0 &&
            dispY.at<float>(i-1,j-1)!=0.0 && dispY.at<float>(i-1,j)!=0.0 && dispY.at<float>(i-1,j+1)!=0.0 && dispY.at<float>(i,j-1)!=0.0 &&
            dispY.at<float>(i,j+1)!=0.0 && dispY.at<float>(i+1,j-1)!=0.0 && dispY.at<float>(i+1,j)!=0.0 && dispY.at<float>(i+1,j+1)!=0.0){
          dispX_tmp.at<float>(i,j)= 0.0;
          dispY_tmp.at<float>(i,j)= 0.0;
        }
      }
    }

    dispX_tmp.copyTo(dispX_tmp2);
    dispY_tmp.copyTo(dispY_tmp2);

    for (int i=1; i<dispX.rows-1; i++){
      for (int j=1; j<dispX.cols-1; j++){
        if (dispX.at<float>(i,j)!=0.0 && dispX_tmp.at<float>(i,j) ==0.0 &&
            (dispX_tmp.at<float>(i-1,j-1)!=0.0 || dispX_tmp.at<float>(i-1,j)!=0.0 ||
             dispX_tmp.at<float>(i-1,j+1)!=0.0 || dispX_tmp.at<float>(i,j-1)!=0.0 ||
             dispX_tmp.at<float>(i,j+1)!=0.0 || dispX_tmp.at<float>(i+1,j-1)!=0.0 ||
             dispX_tmp.at<float>(i+1,j)!=0.0 || dispX_tmp.at<float>(i+1,j+1)!=0.0 ) ){

          dispX_tmp2.at<float>(i,j) = dispX.at<float>(i,j);
          dispY_tmp2.at<float>(i,j) = dispY.at<float>(i,j);
        }

      }
    }

    //double the TPs
    dispX_tmp2.copyTo(dispX);
    dispY_tmp2.copyTo(dispY);
  }


  if (dispX.depth()==2 && dispY.depth()==2){
    dispX.convertTo(dispX, CV_16UC1);
    dispY.convertTo(dispY, CV_16UC1);
    vector<ushort> Lx, Ly;
    vector<float> Rx, Ry;
    for (int i=0; i<dispX.rows; i++){
      for (int j=0; j<dispX.cols; j++){
        if(dispX.at<ushort>(i,j)!=65535 && dispY.at<ushort>(i,j)!=65535){
          unsigned short lx, ly;
          float rx, ry;
          lx = j;
          ly = i;
          rx = j + (dispX.at<ushort>(i,j)-16384)/16.;
          ry = i + (dispY.at<ushort>(i,j)-16384)/16.;
          Lx.push_back(lx);
          Ly.push_back(ly);
          Rx.push_back(rx);
          Ry.push_back(ry);
        }
      }
    }

#if 1
    // Keep the TP in memory, not on disk, this way one can run multiple threads
    // doing Gotcha.
    int nLen = Lx.size();
    vecTPs.resize(nLen);
    for (int i = 0 ; i < nLen; i++){
      unsigned short lx, ly;
      float rx, ry;
      lx = Lx.at(i);
      ly = Ly.at(i);
      rx = Rx.at(i);
      ry = Ry.at(i);
      
      CTiePt tp;
      tp.m_ptL.x = lx;
      tp.m_ptL.y = ly;
      tp.m_ptR.x = rx;
      tp.m_ptR.y = ry;
      tp.m_fSimVal = 0.5;
      vecTPs[i] = tp;
    }
#else
    ofstream sfTP;
    std::cout << "Writing: " << m_strTPFile << std::endl;
    sfTP.open(m_strTPFile.c_str());
    sfTP.precision(10);
    int nLen = Lx.size();
    int nEle = 5;
    if (sfTP.is_open()){
      sfTP << nLen << " " << nEle << std::endl;
      for (int i = 0 ; i < nLen ;i++){
        unsigned short lx, ly;
        float rx, ry;
        lx = Lx.at(i);
        ly = Ly.at(i);
        rx = Rx.at(i);
        ry = Ry.at(i);
        sfTP << lx << " " << ly << " "
             << rx << " " << ry << " "
             << 0.5 << " " << std::endl;
      }
      sfTP.close();
    }
    else {
      std::cout << "ERROR: Can not convert X/Y disparity map to TP file. "
           << "Please check the directory for storing Gotcha results is writable."
           << std::endl;
    }
#endif
    
  } else if (dispX.depth()==5 && dispY.depth()==5){
    dispX.convertTo(dispX, CV_32FC1);
    dispY.convertTo(dispY, CV_32FC1);
    vector<ushort> Lx, Ly;
    vector<float> Rx, Ry;
    for (int i=0; i<dispX.rows; i++){
      for (int j=0; j<dispX.cols; j++){
        if(dispX.at<float>(i,j)!= 0.0 && dispY.at<float>(i,j)!=0.0){

          //nodata should be -3.40282346639e+038, but ASP disparity map uses 0 as nodata
          unsigned short lx, ly;
          float rx, ry;
          lx = j;
          ly = i;
          rx = j + dispX.at<float>(i,j);
          ry = i + dispY.at<float>(i,j);
          Lx.push_back(lx);
          Ly.push_back(ly);
          Rx.push_back(rx);
          Ry.push_back(ry);
        }
      }
    }

#if 1
    // Keep the TP in memory, not on disk, this way one can run multiple threads
    // doing Gotcha.
    int nLen = Lx.size();
    vecTPs.resize(nLen);
    for (int i = 0 ; i < nLen; i++){
      unsigned short lx, ly;
      float rx, ry;
      lx = Lx.at(i);
      ly = Ly.at(i);
      rx = Rx.at(i);
      ry = Ry.at(i);
      
      CTiePt tp;
      tp.m_ptL.x = lx;
      tp.m_ptL.y = ly;
      tp.m_ptR.x = rx;
      tp.m_ptR.y = ry;
      tp.m_fSimVal = 0.5;
      vecTPs[i] = tp;
    }
#else
    ofstream sfTP;
    sfTP.open(m_strTPFile.c_str());
    std::cout << "Writing: " << m_strTPFile << std::endl;
    sfTP.precision(10);
    int nLen = Lx.size();
    int nEle = 5;
    if (sfTP.is_open()){
      sfTP << nLen << " " << nEle << std::endl;
      for (int i = 0 ; i < nLen ;i++){
        unsigned short lx, ly;
        float rx, ry;
        lx = Lx.at(i);
        ly = Ly.at(i);
        rx = Rx.at(i);
        ry = Ry.at(i);
        sfTP << lx << " " << ly << " "
             << rx << " " << ry << " "
             << 0.5 << " " << std::endl;
      }
      sfTP.close();
    } else {
      std::cout << "ERROR: Can not convert X/Y disparity map to TP file. "
           << "Please check the directory for storing Gotcha results is writable." << std::endl;
    }
#endif
  }
  
}

void CBatchProc::refinement(std::vector<CTiePt> const& vecTPs,
                            vw::ImageView<float> & output_dispX,
                            vw::ImageView<float> & output_dispY) {
  //std::cout << "Gotcha densification based on existing disparity map:" << std::endl;
  FileStorage fs(m_strMetaFile, FileStorage::READ);
  FileNode tl = fs["sGotchaParam"];

  // read GOTCHA param
  CDensifyParam paramDense;
  paramDense.m_nProcType = 0;
  paramDense.m_paramGotcha.m_fDiffCoef = 0.05;
  paramDense.m_paramGotcha.m_fDiffThr = 0.1;
  paramDense.m_paramGotcha.m_nDiffIter = 5;
  //paramDense.m_paramGotcha.m_nMinTile = (int)tl["nMinTile"];
  //Mat matDummy = imread(m_strImgL, CV_LOAD_IMAGE_ANYDEPTH);
  paramDense.m_paramGotcha.m_nMinTile = m_imgL.cols + m_imgL.rows;
  paramDense.m_paramGotcha.m_nNeiType = (int)tl["nNeiType"];

  paramDense.m_paramGotcha.m_paramALSC.m_bIntOffset = (int)tl["bIntOffset"];
  paramDense.m_paramGotcha.m_paramALSC.m_bWeighting = (int)tl["bWeight"];
  paramDense.m_paramGotcha.m_paramALSC.m_fAffThr = (float)tl["fAff"];
  paramDense.m_paramGotcha.m_paramALSC.m_fDriftThr = (float)tl["fDrift"];
  paramDense.m_paramGotcha.m_paramALSC.m_fEigThr = (float)tl["fMaxEigenValue"];
  paramDense.m_paramGotcha.m_paramALSC.m_nMaxIter = (int)tl["nALSCIteration"];
  paramDense.m_paramGotcha.m_paramALSC.m_nPatch = (int)tl["nALSCKernel"];

#if 0
  string strBase = m_strOutPath;
  string strTPFile = "-TP.txt";
  paramDense.m_strTPFile = strBase + strTPFile;
  paramDense.m_paramGotcha.m_strMask = m_strMask;
  string strUpdatedDispX = "-c1_refined.txt";
  paramDense.m_strUpdatedDispX = strBase + strUpdatedDispX;
  string strUpdatedDispY = "-c2_refined.txt";
  paramDense.m_strUpdatedDispY = strBase + strUpdatedDispY;
  string strUpdatedDispSim = "-uncertainty.txt";
  paramDense.m_strUpdatedDispSim = strBase + strUpdatedDispSim;

  paramDense.m_strImgL = m_strImgL;
  paramDense.m_strImgR = m_strImgR;
  paramDense.m_strOutPath = m_strOutPath;
  paramDense.m_strDispX = m_strDispX;
  paramDense.m_strDispY = m_strDispY;
  paramDense.m_Mask = m_Mask;
#endif
  
  CDensify densify(paramDense, vecTPs, m_imgL, m_imgR, m_input_dispX, m_input_dispY, m_Mask);
  //std::cout << "CASP-GO INFO: performing Gotcha densification" << std::endl;

  cv::Mat cv_output_dispX, cv_output_dispY;
  int nErrCode = densify.performDensitification(cv_output_dispX, cv_output_dispY);
  if (nErrCode != CDensifyParam::NO_ERR){
    std::cerr << "Warning: Processing error on densifying operation (ERROR CODE: " << nErrCode << " )" << std::endl;
  }

  // Export the data to ASP
  cvMatToAspMat(cv_output_dispX, output_dispX);
  cvMatToAspMat(cv_output_dispY, output_dispY);
}

Point3f CBatchProc::rotate(Point3f ptIn, Mat matQ, bool bInverse){
  // this believe matQ is a unit vector
  Point3f ptRes;

  float p[4] = {0, ptIn.x, ptIn.y, ptIn.z};
  float q[4];
  float q_inv[4];
  // get quaternion vector
  for(int i = 0; i < 4; i++) {
    q[i] = matQ.at<float>(i,0);
    q_inv[i] = -1 * matQ.at<float>(i,0);
  }
  q_inv[0] = -1 * q_inv[0]; // q = [w x y z] and q^-1 = [w -x -y -z]

  // compute rotation
  // [0 v'] = q[0 v]q^-1
  float pfTemp[4] = {0.f,};
  float pfTemp2[4] = {0.f,};
  if (bInverse){
    quaternionMultiplication(q_inv, p, pfTemp);
    quaternionMultiplication(pfTemp, q, pfTemp2);
  }
  else{
    quaternionMultiplication(q, p, pfTemp);
    quaternionMultiplication(pfTemp, q_inv, pfTemp2);
  }

  ptRes.x = pfTemp2[1];
  ptRes.y = pfTemp2[2];
  ptRes.z = pfTemp2[3];

  return ptRes;
}

void CBatchProc::quaternionMultiplication(const float* p, const float* q, float* pfOut){
  // compute p*q = pfOut
  //    x =  q1.x * q2.w + q1.y * q2.z - q1.z * q2.y + q1.w * q2.x;
  //    y = -q1.x * q2.z + q1.y * q2.w + q1.z * q2.x + q1.w * q2.y;
  //    z =  q1.x * q2.y - q1.y * q2.x + q1.z * q2.w + q1.w * q2.z;
  //    w = -q1.x * q2.x - q1.y * q2.y - q1.z * q2.z + q1.w * q2.w;
  // float a = p[0], b = p[1], c = p[2], d =p[3];
  pfOut[0] = p[0]*q[0] - (p[1]*q[1]+p[2]*q[2]+p[3]*q[3]); // w1*w2-v1.v2;
  pfOut[1] = p[1]*q[0] + p[2]*q[3] - p[3]*q[2] + p[0]*q[1];
  pfOut[2] = -1*p[1]*q[3] + p[2]*q[0] + p[3]*q[1] + p[0]*q[2];
  pfOut[3] = p[1]*q[2] - p[2]*q[1] + p[3]*q[0] + p[0]*q[3];
}

} // end namespace gotcha
