#!/bin/bash

VERSION="0.0"

# Check dependencies

PROGRAM_DEPENDENCIES=( 'antsRegistration' 'antsApplyTransforms' 'N4BiasFieldCorrection' 'Atropos' 'KellyKapowski' )
SCRIPTS_DEPENDENCIES=( 'antsBrainExtraction.sh' 'antsAtroposN4.sh' 'antsMultivariateTemplateConstruction2.sh' 'antsMalfLabeling.sh' )

for D in ${PROGRAM_DEPENDENCIES[@]};
  do
    if [[ ! -s ${ANTSPATH}/${D} ]];
      then
        echo "Error:  we can't find the $D program."
        echo "Perhaps you need to \(re\)define \$ANTSPATH in your environment."
        exit
      fi
  done

for D in ${SCRIPT_DEPENDENCIES[@]};
  do
    if [[ ! -s ${ANTSPATH}/${D} ]];
      then
        echo "We can't find the $D script."
        echo "Perhaps you need to \(re\)define \$ANTSPATH in your environment."
        exit
      fi
  done

function Usage {
    cat <<USAGE

`basename $0` performs a longitudinal cortical thickness estimation.  The following steps
are performed:
  1. Create a single-subject template (SST) from all the data
  2. Create priors for the SST
     a. Run the SST through the individual cortical thickness pipeline.
     b. The brain extraction SST prior is created by smoothing the brain extraction
        mask created during 2a.
     c. If labeled atlases are not provided, we smooth the posteriors from 2a to create
        the SST segmentation priors, otherwise we use antsMalfLabeling to create a set of
        posteriors (https://github.com/ntustison/antsCookTemplatePriorsExample).
  3. Using the SST + priors, we run each subject through the antsCorticalThickness
     pipeline.

Usage:

`basename $0` -d imageDimension
              -e brainTemplate
              -m brainExtractionProbabilityMask
              -p brainSegmentationPriors
              <OPTARGS>
              -o outputPrefix
              ${anatomicalImages[@]}

Example:

  bash $0 -d 3 -e brainWithSkullTemplate.nii.gz -m brainPrior.nii.gz -p segmentationPriors%d.nii.gz -o output ${anatomicalImages[@]}

Required arguments:

     -d:  Image dimension                       2 or 3 (for 2- or 3-dimensional image)
     -e:  Brain template                        Anatomical *intensity* template (possibly created using a population
                                                data set with buildtemplateparallel.sh in ANTs).  This template is
                                                *not* skull-stripped.
     -m:  Brain extraction probability mask     Brain *probability* mask created using e.g. LPBA40 labels which
                                                have brain masks defined, and warped to anatomical template and
                                                averaged resulting in a probability image.
     -p:  Brain segmentation priors             Tissue *probability* priors corresponding to the image specified
                                                with the -e option.  Specified using c-style formatting, e.g.
                                                -p labelsPriors%02d.nii.gz.  We assume that the first four priors
                                                are ordered as follows
                                                  1:  csf
                                                  2:  cortical gm
                                                  3:  wm
                                                  4:  deep gm
     -o:  Output prefix                         The following subdirectory and images are created for the single
                                                subject template
                                                  * ${OUTPUT_PREFIX}SingleSubjectTemplate/
                                                  * ${OUTPUT_PREFIX}SingleSubjectTemplate/T_template*.nii.gz

     anatomical images                          Set of multimodal input data assumed to be specified ordered as
                                                follows:
                                                   ${subject1_modality1} ${subject1_modality2} ...
                                                   ${subject2_modality1} ${subject2_modality2} ...
                                                   .
                                                   .
                                                   .
                                                   ${subjectN_modality1} ${subjectN_modality2}

Optional arguments:

     -s:  image file suffix                     Any of the standard ITK IO formats e.g. nrrd, nii.gz (default), mhd
     -c:  control type                          Control for parallel computation (default 0):
                                                  0 = run serially
                                                  1 = SGE qsub
                                                  2 = use PEXEC (localhost)
                                                  3 = Apple XGrid
                                                  4 = PBS qsub
     -a:                                        Atlases (assumed to be skull-stripped) used to cook template priors.  If atlases
                                                aren't used then we simply smooth the single-subject template posteriors after
                                                passing through antsCorticalThickness.sh.
     -l:                                        Labels associated with the atlases (-a).  Number of labels is assumed to be equal
                                                to the number of priors.
     -f:  extraction registration mask          Mask (defined in the template space) used during registration
                                                for brain extraction.
     -j:  Number of cpu cores                   Number of cpu cores to use locally for pexec option (default 2; requires "-c 2")
     -k:  number of modalities                  Number of modalities used to construct the template (default 1):  For example,
                                                if one wanted to use multiple modalities consisting of T1, T2, and FA
                                                components ("-k 3").
     -g:  use floating-point precision          Use floating point precision in registrations (default = 0)
     -w:  Atropos prior segmentation weight     Atropos spatial prior *probability* weight for the segmentation (default = 0.25)
     -q:  Use quick registration parameters     If = 1, use antsRegistrationSyNQuick.sh as the basis for registration
                                                during brain extraction, brain segmentation, and (optional) normalization
                                                to a template.  Otherwise use antsRegistrationSyN.sh (default = 0).

     -z:  Test / debug mode                     If > 0, runs a faster version of the script. Only for testing. Implies -u 0.
                                                Requires single thread computation for complete reproducibility.
USAGE
    exit 1
}

echoParameters() {
    cat <<PARAMETERS

    Using antsLongitudinalCorticalThickness with the following arguments:
      image dimension         = ${DIMENSION}
      anatomical image        = ${ANATOMICAL_IMAGES[@]}
      brain template          = ${BRAIN_TEMPLATE}
      extraction prior        = ${EXTRACTION_PRIOR}
      segmentation prior      = ${SEGMENTATION_PRIOR}
      output prefix           = ${OUTPUT_PREFIX}
      output image suffix     = ${OUTPUT_SUFFIX}
      registration template   = ${REGISTRATION_TEMPLATE}

    Other parameters:
      run quick               = ${RUN_QUICK}
      debug mode              = ${DEBUG_MODE}
      float precision         = ${USE_FLOAT_PRECISION}
      use random seeding      = ${USE_RANDOM_SEEDING}
      number of modalities    = ${NUMBER_OF_MODALITIES}
      number of cores         = ${CORES}
      control type            = ${DOQSUB}

PARAMETERS
}

# Echos a command to stdout, then runs it
# Will immediately exit on error unless you set debug flag here
DEBUG_MODE=0

function logCmd() {
  cmd="$*"
  echo "BEGIN >>>>>>>>>>>>>>>>>>>>"
  echo $cmd
  $cmd

  cmdExit=$?

  if [[ $cmdExit -gt 0 ]];
    then
      echo "ERROR: command exited with nonzero status $cmdExit"
      echo "Command: $cmd"
      echo
      if [[ ! $DEBUG_MODE -gt 0 ]];
        then
          exit 1
        fi
    fi

  echo "END   <<<<<<<<<<<<<<<<<<<<"
  echo
  echo

  return $cmdExit
}

################################################################################
#
# Main routine
#
################################################################################

HOSTNAME=`hostname`
DATE=`date`

CURRENT_DIR=`pwd`/
OUTPUT_DIR=${CURRENT_DIR}/tmp$RANDOM/
OUTPUT_PREFIX=${OUTPUT_DIR}/tmp
OUTPUT_SUFFIX="nii.gz"

DIMENSION=3

NUMBER_OF_MODALITIES=1

ANATOMICAL_IMAGES=()
RUN_QUICK=1
USE_RANDOM_SEEDING=1

BRAIN_TEMPLATE=""
EXTRACTION_PRIOR=""
EXTRACTION_REGISTRATION_MASK=""
SEGMENTATION_PRIOR=""

ATROPOS_SEGMENTATION_PRIOR_WEIGHT=0.25

DOQSUB=0
CORES=2

MALF_ATLASES=()
MALF_LABELS=()
MALF_LABEL_STRINGS_FOR_PRIORS=()

FORMAT=${SEGMENTATION_PRIOR}
PREFORMAT=${FORMAT%%\%*}
POSTFORMAT=${FORMAT##*d}
FORMAT=${FORMAT#*\%}
FORMAT=${FORMAT%%d*}

REPCHARACTER=''
TOTAL_LENGTH=0
if [ ${#FORMAT} -eq 2 ]
  then
    REPCHARACTER=${FORMAT:0:1}
    TOTAL_LENGTH=${FORMAT:1:1}
  fi

# MAXNUMBER=$(( 10 ** $TOTAL_LENGTH ))
MAXNUMBER=1000

PRIOR_IMAGE_FILENAMES=()
WARPED_PRIOR_IMAGE_FILENAMES=()
BRAIN_SEGMENTATION_OUTPUT=${OUTPUT_PREFIX}BrainSegmentation
SEGMENTATION_WARP_OUTPUT_PREFIX=${BRAIN_SEGMENTATION_OUTPUT}Prior
SEGMENTATION_PRIOR_WARPED=${SEGMENTATION_WARP_OUTPUT_PREFIX}Warped
for (( i = 1; i < $MAXNUMBER; i++ ))
  do
    NUMBER_OF_REPS=$(( $TOTAL_LENGTH - ${#i} ))
    ROOT='';
    for(( j=0; j < $NUMBER_OF_REPS; j++ ))
      do
        ROOT=${ROOT}${REPCHARACTER}
      done
    FILENAME=${PREFORMAT}${ROOT}${i}${POSTFORMAT}
    WARPED_FILENAME=${SEGMENTATION_PRIOR_WARPED}${ROOT}${i}.${OUTPUT_SUFFIX}
    if [[ -f $FILENAME ]];
      then
        PRIOR_IMAGE_FILENAMES=( ${PRIOR_IMAGE_FILENAMES[@]} $FILENAME )
        WARPED_PRIOR_IMAGE_FILENAMES=( ${WARPED_PRIOR_IMAGE_FILENAMES[@]} $WARPED_FILENAME )
      else
        break 1
      fi
  done

NUMBER_OF_PRIOR_IMAGES=${#WARPED_PRIOR_IMAGE_FILENAMES[*]}

################################################################################
#
# Programs and their parameters
#
################################################################################

USE_FLOAT_PRECISION=0

if [[ $# -lt 3 ]] ; then
  Usage >&2
  exit 1
else
  while getopts "a:b:c:d:e:f:g:h:j:k:l:m:o:p:q:s:w:z:" OPT
    do
      case $OPT in
          a)
       MALF_ATLASES[${#MALF_ATLASES[@]}]=$OPTARG
       ;;
          b) # posterior formulation
       ATROPOS_SEGMENTATION_POSTERIOR_FORMULATION=$OPTARG
       ;;
          c)
       DOQSUB=$OPTARG
       if [[ $DOQSUB -gt 4 ]];
         then
           echo " DOQSUB must be an integer value (0=serial, 1=SGE qsub, 2=try pexec, 3=XGrid, 4=PBS qsub ) you passed  -c $DOQSUB "
           exit 1
         fi
       ;;
          d) #dimensions
       DIMENSION=$OPTARG
       if [[ ${DIMENSION} -gt 3 || ${DIMENSION} -lt 2 ]];
         then
           echo " Error:  ImageDimension must be 2 or 3 "
           exit 1
         fi
       ;;
          e) #brain extraction anatomical image
       BRAIN_TEMPLATE=$OPTARG
       ;;
          f) #brain extraction registration mask
       EXTRACTION_REGISTRATION_MASK=$OPTARG
       ;;
          g) #use floating point precision
       USE_FLOAT_PRECISION=$OPTARG
       ;;
          h) #help
       Usage >&2
       exit 0
       ;;
          j) #number of cpu cores to use (default = 2)
       CORES=$OPTARG
       ;;
          k) #number of modalities
       NUMBER_OF_MODALITIES=$OPTARG
       ;;
          l)
       MALF_LABELS[${#MALF_LABELS[@]}]=$OPTARG
       ;;
          m) #brain extraction prior probability mask
       EXTRACTION_PRIOR=$OPTARG
       ;;
          o) #output prefix
       OUTPUT_PREFIX=$OPTARG
       ;;
          p) #brain segmentation label prior image
       SEGMENTATION_PRIOR=$OPTARG
       ;;
          q) # run quick
       RUN_QUICK=$OPTARG
       ;;
          w) #atropos prior weight
       ATROPOS_SEGMENTATION_PRIOR_WEIGHT=$OPTARG
       ;;
          z) #debug mode
       DEBUG_MODE=$OPTARG
       ;;
          *) # getopts issues an error message
       echo "ERROR:  unrecognized option -$OPT $OPTARG"
       exit 1
       ;;
      esac
  done
fi

# Shiftsize is calculated because a variable amount of arguments can be used on the command line.
# The shiftsize variable will give the correct number of arguments to skip. Issuing shift $shiftsize will
# result in skipping that number of arguments on the command line, so that only the input images remain.
shiftsize=$(($OPTIND - 1))
shift $shiftsize
# The invocation of $* will now read all remaining arguments into the variable IMAGESETVARIABLE
IMAGESETVARIABLE=$*
NINFILES=$(($nargs - $shiftsize))
IMAGESETARRAY=()

for IMG in $IMAGESETVARIABLE
  do
    ANATOMICAL_IMAGES[${#ANATOMICAL_IMAGES[@]}]=$IMG
  done

if [[ ${#ANATOMICAL_IMAGES[@]} -eq 0 ]];
  then
    echo "Error:  no anatomical images specified."
    exit 1
  fi

if [[ $NUMBER_OF_MODALITIES -gt 1 ]];
  then
    echo "--------------------------------------------------------------------------------------"
    echo " Cortical thickness using the following ${NUMBER_OF_MODALITIES}-tuples:  "
    echo "--------------------------------------------------------------------------------------"
    for (( i = 0; i < ${#ANATOMICAL_IMAGES[@]}; i+=$NUMBER_OF_MODALITIES ))
      do
        IMAGEMETRICSET=""
        for (( j = 0; j < $ANATOMICAL_IMAGES; j++ ))
          do
            k=0
            let k=$i+$j
            IMAGEMETRICSET="$IMAGEMETRICSET ${ANATOMICAL_IMAGES[$k]}"
          done
        echo $IMAGEMETRICSET
      done
    echo "--------------------------------------------------------------------------------------"
fi

if [[ ${#MALF_ATLASES[@]} -ne ${#MALF_LABELS[@]} ]]
  then
    echo "Error:  The number of malf atlases and labels aren't equal."
  fi

################################################################################
#
# Preliminaries:
#  1. Check existence of inputs
#  2. Figure out output directory and mkdir if necessary
#  3. See if $REGISTRATION_TEMPLATE is the same as $BRAIN_TEMPLATE
#
################################################################################

for (( i = 0; i < ${#ANATOMICAL_IMAGES[@]}; i++ ))
  do
  if [[ ! -f ${ANATOMICAL_IMAGES[$i]} ]];
    then
      echo "The specified image \"${ANATOMICAL_IMAGES[$i]}\" does not exist."
      exit 1
    fi
  done

if [[ ! -f ${BRAIN_TEMPLATE} ]];
  then
    echo "The extraction template doesn't exist:"
    echo "   $BRAIN_TEMPLATE"
    exit 1
  fi
if [[ ! -f ${EXTRACTION_PRIOR} ]];
  then
    echo "The brain extraction prior doesn't exist:"
    echo "   $EXTRACTION_PRIOR"
    exit 1
  fi

OUTPUT_DIR=${OUTPUT_PREFIX%\/*}
if [[ ! -d $OUTPUT_DIR ]];
  then
    echo "The output directory \"$OUTPUT_DIR\" does not exist. Making it."
    mkdir -p $OUTPUT_DIR
  fi

echoParameters >&2

echo "---------------------  Running `basename $0` on $HOSTNAME  ---------------------"

time_start=`date +%s`

################################################################################
#
# Single-subject template creation
#
################################################################################

echo
echo "--------------------------------------------------------------------------------------"
echo " Creating single-subject template                                                     "
echo "--------------------------------------------------------------------------------------"
echo

TEMPLATE_MODALITY_WEIGHT_VECTOR='1'
for(( i=1; i < ${NUMBER_OF_MODALITIES}; i++ ))
  do
    TEMPLATE_MODALITY_WEIGHT_VECTOR="${TEMPLATE_MODALITY_WEIGHT_VECTOR}x1"
  done

TEMPLATE_Z_IMAGES=''
for(( i=0; i < ${NUMBER_OF_MODALITIES}; i++ ))
  do
    TEMPLATE_Z_IMAGES="${TEMPLATE_Z_IMAGES} -z ${ANATOMICAL_IMAGES[$i]}"
  done

OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE="${OUTPUT_PREFIX}SingleSubjectTemplate/"
SINGLE_SUBJECT_TEMPLATE=${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}T_template0.nii.gz

time_start_sst_creation=`date +%s`

if [[ ! -f $SINGLE_SUBJECT_TEMPLATE ]];
  then

#     logCmd ${ANTSPATH}/antsMultivariateTemplateConstruction2.sh \
#       -d ${DIMENSION} \
#       -o ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}T_ \
#       -a 0 \
#       -b 0 \
#       -g 0.25 \
#       -i 4 \
#       -c ${DOQSUB} \
#       -j ${CORES} \
#       -e ${USE_FLOAT_PRECISION} \
#       -k ${NUMBER_OF_MODALITIES} \
#       -w ${TEMPLATE_MODALITY_WEIGHT_VECTOR} \
#       -q 100x70x30x3  \
#       -f 8x4x2x1 \
#       -s 3x2x1x0 \
#       -n 1 \
#       -r 1 \
#       -l 1 \
#       -m CC[4] \
#       -t SyN \
#       ${TEMPLATE_Z_IMAGES} \
#       ${ANATOMICAL_IMAGES[@]}

    logCmd ${ANTSPATH}/antsMultivariateTemplateConstruction.sh \
      -d ${DIMENSION} \
      -o ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}T_ \
      -b 0 \
      -g 0.25 \
      -i 4 \
      -c ${DOQSUB} \
      -j ${CORES} \
      -k ${NUMBER_OF_MODALITIES} \
      -w ${TEMPLATE_MODALITY_WEIGHT_VECTOR} \
      -m 100x70x30x3  \
      -n 1 \
      -r 1 \
      -s CC \
      -t GR \
      ${TEMPLATE_Z_IMAGES} \
      ${ANATOMICAL_IMAGES[@]}

  fi

if [[ ! -f ${SINGLE_SUBJECT_TEMPLATE} ]];
  then
    echo "Error:  The single subject template was not created.  Exiting."
    exit 1
  fi

# clean up

logCmd rm -f ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}job*.sh
logCmd rm -f ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}job*.txt
logCmd rm -f ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}rigid*
logCmd rm -f ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}*Repaired*
logCmd rm -f ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}*WarpedToTemplate*
logCmd rm -f ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}T_*Warp.nii.gz
logCmd rm -f ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}T_*Affine.txt
logCmd rm -f ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}T_*GenericAffine*
logCmd rm -f ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}T_template0warp.nii.gz
logCmd rm -f ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}T_template0Affine.txt
logCmd rm -f ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}T_templatewarplog.txt

# Need to change the number of iterations to  -q \

time_end_sst_creation=`date +%s`
time_elapsed_sst_creation=$((time_end_sst_creation - time_start_sst_creation))

echo
echo "--------------------------------------------------------------------------------------"
echo " Done with single subject template:  $(( time_elapsed_sst_creation / 3600 ))h $(( time_elapsed_sst_creation %3600 / 60 ))m $(( time_elapsed_sst_creation % 60 ))s"
echo "--------------------------------------------------------------------------------------"
echo

################################################################################
#
#  Create template priors
#
################################################################################

SINGLE_SUBJECT_ANTSCT_PREFIX=${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}/T_template
SINGLE_SUBJECT_TEMPLATE_EXTRACTION_MASK=${SINGLE_SUBJECT_ANTSCT_PREFIX}BrainExtractionMask.${OUTPUT_SUFFIX}

echo
echo "--------------------------------------------------------------------------------------"
echo " Creating template priors:  running SST through antsCorticalThickness                 "
echo "--------------------------------------------------------------------------------------"
echo

time_start_priors=`date +%s`

logCmd ${ANTSPATH}/antsCorticalThickness.sh \
  -d ${DIMENSION} \
  -q ${RUN_QUICK} \
  -a ${SINGLE_SUBJECT_TEMPLATE} \
  -e ${BRAIN_TEMPLATE} \
  -m ${EXTRACTION_PRIOR} \
  -k 0 \
  -p ${SEGMENTATION_PRIOR} \
  -o ${SINGLE_SUBJECT_ANTSCT_PREFIX}

time_end_priors=`date +%s`
time_elapsed_priors=$((time_end_priors - time_start_priors))

SINGLE_SUBJECT_TEMPLATE_POSTERIORS=( ${SINGLE_SUBJECT_ANTSCT_PREFIX}BrainSegmentationPosteriors*.${OUTPUT_SUFFIX} )
SINGLE_SUBJECT_TEMPLATE_SEGMENTATION_PRIOR=${SINGLE_SUBJECT_ANTSCT_PREFIX}BrainSegmentationPriors\%${FORMAT}d.${OUTPUT_SUFFIX}
SINGLE_SUBJECT_TEMPLATE_EXTRACTION_PRIOR=${SINGLE_SUBJECT_ANTSCT_PREFIX}BrainExtractionMaskPrior.${OUTPUT_SUFFIX}
SINGLE_SUBJECT_TEMPLATE_SKULL_STRIPPED=${SINGLE_SUBJECT_ANTSCT_PREFIX}BrainExtractionBrain.${OUTPUT_SUFFIX}

logCmd ${ANTSPATH}/ImageMath ${DIMENSION} ${SINGLE_SUBJECT_TEMPLATE_SKULL_STRIPPED} m ${SINGLE_SUBJECT_TEMPLATE} ${SINGLE_SUBJECT_TEMPLATE_EXTRACTION_MASK}

logCmd ${ANTSPATH}/SmoothImage ${DIMENSION} ${SINGLE_SUBJECT_TEMPLATE_EXTRACTION_MASK} 1 ${SINGLE_SUBJECT_TEMPLATE_EXTRACTION_PRIOR} 1

if [[ ${#MALF_ATLASES[@]} -eq 0 ]];
  then

    echo
    echo "   ---> Smoothing single-subject template posteriors as priors."
    echo

    for j in ${SINGLE_SUBJECT_TEMPLATE_POSTERIORS[@]}
      do
        PRIOR=${j/Posteriors/Priors}
        logCmd ${ANTSPATH}/SmoothImage ${DIMENSION} $j 1 $PRIOR 1
      done

  else

    echo
    echo "   ---> Cooking single-subject priors using antsMalfLabeling."
    echo

    SINGLE_SUBJECT_TEMPLATE_MALF_LABELS_PREFIX=${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_TEMPLATE}/T_template
    SINGLE_SUBJECT_TEMPLATE_MALF_LABELS=${SINGLE_SUBJECT_TEMPLATE_MALF_LABELS_PREFIX}MalfLabels.nii.gz

    ATLAS_AND_LABELS_STRING=''
    for (( j=0; j < ${#MALF_ATLASES[@]}; j++ ))
      do
        ATLAS_AND_LABELS_STRING="${ATLAS_AND_LABELS_STRING} -g ${MALF_ATLASES[$j]} -l ${MALF_LABELS[$j]}"
      done

    logCmd ${ANTSPATH}/antsMalfLabeling.sh \
      -d ${DIMENSION} \
      -q ${RUN_QUICK} \
      -c ${DOQSUB} \
      -j ${CORES} \
      -t ${SINGLE_SUBJECT_TEMPLATE_SKULL_STRIPPED} \
      -o ${SINGLE_SUBJECT_TEMPLATE_MALF_LABELS_PREFIX} \
      ${ATLAS_AND_LABELS_STRING}

    SINGLE_SUBJECT_TEMPLATE_PRIORS=()
    for (( j = 0; j < ${#SINGLE_SUBJECT_TEMPLATE_POSTERIORS[@]}; j++ ))
      do
        POSTERIOR=${SINGLE_SUBJECT_TEMPLATE_POSTERIORS[$j]}

        SINGLE_SUBJECT_TEMPLATE_PRIORS[$j]=${POSTERIOR/Posteriors/Priors}

        let PRIOR_LABEL=$j+1
        logCmd ${ANTSPATH}/ThresholdImage ${DIMENSION} ${SINGLE_SUBJECT_TEMPLATE_MALF_LABELS} ${SINGLE_SUBJECT_TEMPLATE_PRIORS[$j]} ${PRIOR_LABEL} ${PRIOR_LABEL} 1 0
        logCmd ${ANTSPATH}/SmoothImage ${DIMENSION} ${SINGLE_SUBJECT_TEMPLATE_PRIORS[$j]} 1 ${SINGLE_SUBJECT_TEMPLATE_PRIORS[$j]} 1
      done

    TMP_CSF_POSTERIOR=${SINGLE_SUBJECT_ANTSCT_PREFIX}BrainSegmentationCsfPosteriorTmp.${OUTPUT_SUFFIX}
    logCmd ${ANTSPATH}/SmoothImage ${DIMENSION} ${SINGLE_SUBJECT_TEMPLATE_POSTERIORS[0]} 1 ${TMP_CSF_POSTERIOR}
    logCmd ${ANTSPATH}/ImageMath ${DIMENSION} ${SINGLE_SUBJECT_TEMPLATE_PRIORS[0]} max ${SINGLE_SUBJECT_TEMPLATE_PRIORS[0]} ${TMP_CSF_POSTERIOR}

    logCmd rm -f $TMP_CSF_POSTERIOR
    logCmd rm -f ${SINGLE_SUBJECT_TEMPLATE_MALF_LABELS_PREFIX}*log.txt
  fi

echo
echo "--------------------------------------------------------------------------------------"
echo " Done with creating template priors:  $(( time_elapsed_priors / 3600 ))h $(( time_elapsed_priors %3600 / 60 ))m $(( time_elapsed_priors % 60 ))s"
echo "--------------------------------------------------------------------------------------"
echo

################################################################################
#
#  Run each individual subject through antsCorticalThickness
#
################################################################################

echo
echo "--------------------------------------------------------------------------------------"
echo " Run each individual through antsCorticalThickness                                    "
echo "--------------------------------------------------------------------------------------"
echo

time_start_antsct=`date +%s`

for (( i=0; i < ${#ANATOMICAL_IMAGES[@]}; i+=$NUMBER_OF_MODALITIES ))
  do

    BASENAME_ID=`basename ${ANATOMICAL_IMAGES[$i]}`
    BASENAME_ID=${BASENAME_ID/\.nii\.gz/}
    BASENAME_ID=${BASENAME_ID/\.nii/}

    OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_CORTICAL_THICKNESS=${OUTPUT_DIR}/${BASENAME_ID}/

    echo $OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_CORTICAL_THICKNESS

    SUBJECT_ANATOMICAL_IMAGES=''
    let k=$i+$NUMBER_OF_MODALITIES
    for (( j=$i; j < $k; j++ ))
      do
        SUBJECT_ANATOMICAL_IMAGES="${SUBJECT_ANATOMICAL_IMAGES} -a ${ANATOMICAL_IMAGES[$j]}"
      done

    logCmd ${ANTSPATH}/antsCorticalThickness.sh \
      -d ${DIMENSION} \
      -q ${RUN_QUICK} \
      ${SUBJECT_ANATOMICAL_IMAGES} \
      -e ${SINGLE_SUBJECT_TEMPLATE} \
      -m ${SINGLE_SUBJECT_TEMPLATE_EXTRACTION_PRIOR} \
      -k 0 \
      -w ${ATROPOS_SEGMENTATION_PRIOR_WEIGHT} \
      -p ${SINGLE_SUBJECT_TEMPLATE_SEGMENTATION_PRIOR} \
      -t ${SINGLE_SUBJECT_TEMPLATE_SKULL_STRIPPED} \
      -o ${OUTPUT_DIRECTORY_FOR_SINGLE_SUBJECT_CORTICAL_THICKNESS}/ants
  done

time_end_antsct=`date +%s`
time_elapsed_antsct=$((time_end_antsct - time_start_antsct))

echo
echo "--------------------------------------------------------------------------------------"
echo " Done with individual cortical thickness:  $(( time_elapsed_antsct / 3600 ))h $(( time_elapsed_antsct %3600 / 60 ))m $(( time_elapsed_antsct % 60 ))s"
echo "--------------------------------------------------------------------------------------"
echo

time_end=`date +%s`
time_elapsed=$((time_end - time_start))

echo
echo "--------------------------------------------------------------------------------------"
echo " Done with ANTs longitudinal processing pipeline"
echo " Script executed in $time_elapsed seconds"
echo " $(( time_elapsed / 3600 ))h $(( time_elapsed %3600 / 60 ))m $(( time_elapsed % 60 ))s"
echo "--------------------------------------------------------------------------------------"

exit 0
