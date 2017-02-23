# source the ciop functions (e.g. ciop-log)
source ${ciop_job_include}

# define the exit codes
SUCCESS=0
ERR_INVALIDFORMAT=2
ERR_NOIDENTIFIER=5
ERR_NODEM=7
ERR_GMTSAR=10
ERR_CENTROID=20

# add a trap to exit gracefully
function cleanExit () {

 local retval=$?
 local msg=""

 case "${retval}" in
   ${SUCCESS})           msg="Processing successfully concluded";;
   ${ERR_INVALIDFORMAT}) msg="Invalid format must be roi_pac, gmtsar or gamma";;
   ${ERR_NOIDENTIFIER})  msg="Could not retrieve the dataset identifier";;
   ${ERR_NODEM})         msg="DEM not generated";;
   ${ERR_GMTSAR})	 msg="GMTSAR failed to generate DEM";;
   ${ERR_CENTROID})	 msg="Failed to extract centroid from WKT";;
   *) msg="Unknown error";;
  esac

  [ "${retval}" != "0" ] && ciop-log "ERROR" "Error ${retval} - ${msg}, processing aborted" || ciop-log "INFO" "${msg}"

  exit ${retval}
}

trap cleanExit EXIT
 
function set_env() {

  export PATH=${_CIOP_APPLICATION_PATH}/srtmdem/bin:${PATH}

  # SRTM.py uses matplotlib, set a temporary directory
  export MPLCONFIGDIR=${TMPDIR}/

  export GMTSAR_HOME=/usr/local/GMTSAR/gmtsar/csh 
 
  export SRTM1=/data/SRTM41/
  export SRTM3=/data/SRTM3/World/
}

function main() {
  
  set_env

  format="$( ciop-getparam format )"

  case ${format} in
    roi_pac)
      option="";;
    gamma)
      option="-g";;
    gmtsar)
      flag="true";;
    *)  
      return ${ERR_INVALIDFORMAT};;
  esac

  cd ${TMPDIR}

  # read the catalogue reference to the dataset
  while read inputfile
  do

    dem_name=$( uuidgen ) 
    [ -z "${dem_name}" ] && return ${ERR_NOIDENTIFIER} 

    wkt="$( opensearch-client "$inputfile" wkt )"
    ciop-log "DEBUG" "wkt is ${wkt}"

    # the centroid R script get the WKT footprint and calculates the geometry centroid
    pts=$( centroid "${wkt}" )
    [ -z "${pts}" ] && return ${ERR_CENTROID}    

    lon=$( echo ${pts} | cut -d " " -f 1 )
    lat=$( echo ${pts} | cut -d " " -f 2 )

    ciop-log "INFO" "$( basename "${inputfile}" ) centroid is (${lon} ${lat})"

    # GMTSAR
    [ "${flag}" == "true" ] && {

      bbox=$( mbr "${wkt}" )

      lon1=$( echo "$( echo "${bbox}" | cut -d "," -f 1 ) -1.5" | bc | cut -d "." -f 1 )
      lon2=$( echo "$( echo "${bbox}" | cut -d "," -f 2 ) +1.5" | bc | cut -d "." -f 1 )
      lat1=$( echo "$( echo "${bbox}" | cut -d "," -f 3 ) -1.5" | bc | cut -d "." -f 1 )
      lat2=$( echo "$( echo "${bbox}" | cut -d "," -f 4 ) +1.5" | bc | cut -d "." -f 1 )
    
      ciop-log "INFO" "using GMTSAR with coords ${lon1} ${lat1} ${lon2} ${lat2} [bbox=$bbox]"

      cd ${TMPDIR}

      export PATH=${PATH}:${GMTSAR_HOME}
      ${GMTSAR_HOME}/make_dem.csh ${lon1} ${lon2} ${lat1} ${lat2} 2 ${SRTM3}
      
      [ ! -e dem.grd ] && return ${ERR_GMTSAR}
   
      # save the bandwidth
      ciop-log "INFO" "Compressing DEM"
    
      tar cfz ${dem_name}.dem.tgz dem*
      rm -fr dem* 
    
    } || {

      # invoke the SRTM.py
      ciop-log "INFO" "Generating DEM"
      SRTM.py ${lat} ${lon} ${TMPDIR}/${dem_name} -D ${SRTM1} ${option} 1>&2
      [ ! -e ${dem_name}.dem ] && return ${ERR_NODEM}
     
      # save the bandwidth 
      ciop-log "INFO" "Compressing DEM"
      tar cfz ${dem_name}.dem.tgz ${dem_name}*   
 
    }

    # have the compressed archive published and its reference exposed as metalink
    ciop-log "INFO" "Publishing results"
    ciop-publish -m ${TMPDIR}/${dem_name}.dem.tgz  
   
    # clean-up for the next dataset reference
    rm -fr ${dem_name}*
 
  done

}
