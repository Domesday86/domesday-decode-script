#!/bin/bash
# Bash script to decode all Domesday AIV images
# 20200218
#
echo "Domesday AIV decode script"

# Check if destination directory exists
if [ -d "/mnt/md0/Decodes/autoAIV" ] 
then
    # Destination exists; do not continue to protect against overwriting
    echo "Directory /mnt/md0/Decodes/autoAIV exists"
    echo "Please delete it before running this script"
    exit 1
else
    # Create the destination directories
    echo "Creating /mnt/md0/Decodes/autoAIV output directories..."
    mkdir /mnt/md0/Decodes/autoAIV
    mkdir /mnt/md0/Decodes/autoAIV/NationalA
    mkdir /mnt/md0/Decodes/autoAIV/NationalB
    mkdir /mnt/md0/Decodes/autoAIV/CommunityN
    mkdir /mnt/md0/Decodes/autoAIV/CommunityS
fi

# Switches
STANDARD="--pal --WibbleRemover"

# Additional switches (used for testing)
#TESTSWITCH="--length 3"
TESTSWITCH=""

# Control what to decode
NATIONALA="true"
NATIONALB="true"
COMMN="true"
COMMS="true"

if [ "$NATIONALA" = "true" ]; then echo "Decoding National A side"; fi
if [ "$NATIONALB" = "true" ]; then echo "Decoding National B side"; fi
if [ "$COMMN" = "true" ]; then echo "Decoding Community North"; fi
if [ "$COMMS" = "true" ]; then echo "Decoding Community South"; fi

# Simon DS1
echo "Decoding Simon DS1..."
if [ "$NATIONALA" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS1/Domesday\ National_CAV_PAL_side1_DS1_pp\ 1-37480_2019-10-14_08-41-01.raw.oga /mnt/md0/Decodes/autoAIV/NationalA/simonds1_nationalA1 $STANDARD --start 310 $TESTSWITCH ; fi
if [ "$NATIONALA" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS1/Domesday\ National_CAV_PAL_side1_DS1_pp\ 39000-54000_2019-10-14_09-07-37.raw.oga /mnt/md0/Decodes/autoAIV/NationalA/simonds1_nationalA2 $STANDARD --start 0 $TESTSWITCH ; fi
if [ "$NATIONALB" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS1/Domesday\ National_CLV_PAL_side2_DS1_pp_2019-10-14_07-22-33.raw.oga /mnt/md0/Decodes/autoAIV/NationalB/simonds1_nationalB $STANDARD --start 205 $TESTSWITCH ; fi
if [ "$COMMN" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS1/Domesday\ Community_CAV_PAL_side1_North\ DS1_2019-10-14_09-47-42.raw.oga /mnt/md0/Decodes/autoAIV/CommunityN/simonds1_commN $STANDARD --start 345 $TESTSWITCH ; fi
if [ "$COMMS" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS1/Domesday\ Community_CAV_PAL_side2_South\ DS1_2019-10-14_10-25-15.raw.oga /mnt/md0/Decodes/autoAIV/CommunityS/simonds1_commS $STANDARD --start 327 $TESTSWITCH ; fi

# Simon DS2
echo "Decoding Simon DS2..."
if [ "$NATIONALA" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS2/Domesday\ National_CAV_PAL_side1_DS2_pp_2019-10-14_11-12-02.raw.oga /mnt/md0/Decodes/autoAIV/NationalA/simonds2_nationalA $STANDARD --start 303 $TESTSWITCH ; fi
if [ "$NATIONALB" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS2/Domesday\ National_CLV_PAL_side2_DS2_pp_2019-10-14_11-49-45.raw.oga /mnt/md0/Decodes/autoAIV/NationalB/simonds2_nationalB $STANDARD --start 214 $TESTSWITCH ; fi
if [ "$COMMN" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS2/Domesday\ Community_CAV_PAL_side1_North\ DS2_2019-10-14_13-08-30.raw.oga /mnt/md0/Decodes/autoAIV/CommunityN/simonds2_commN $STANDARD --start 336 $TESTSWITCH ; fi
if [ "$COMMS" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS2/Domesday\ Community_CAV_PAL_side2_South\ DS2_2019-10-14_13-46-04.raw.oga /mnt/md0/Decodes/autoAIV/CommunityS/simonds2_commS $STANDARD --start 297 $TESTSWITCH ; fi

# Simon DS3
echo "Decoding Simon DS3..."
if [ "$NATIONALA" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS3/Domesday\ National_CAV_PAL_side1_DS3\ 1-50848_2019-10-14_14-49-31.raw.oga /mnt/md0/Decodes/autoAIV/NationalA/simonds3_nationalA $STANDARD --start 309 $TESTSWITCH ; fi
if [ "$NATIONALB" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS3/Domesday\ National_CLV_PAL_side2_DS3\ 0-58m_2019-10-14_15-36-10.raw.oga /mnt/md0/Decodes/autoAIV/NationalB/simond3_nationalB $STANDARD --start 184 $TESTSWITCH ; fi
if [ "$COMMN" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS3/Domesday\ Community_CLV_PAL_side1_North\ DS3_2019-10-14_17-17-11.raw.oga /mnt/md0/Decodes/autoAIV/CommunityN/simonds3_commN $STANDARD --start 298 $TESTSWITCH ; fi
if [ "$COMMS" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS3/Domesday\ Community_CLV_PAL_side2_South\ DS3_1-53040_2019-10-14_17-57-58.raw.oga /mnt/md0/Decodes/autoAIV/CommunityS/simonds3_commS $STANDARD --start 261 $TESTSWITCH ; fi

# Simon DS4
echo "Decoding Simon DS4..."
if [ "$NATIONALA" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS4/Domesday\ National_CAV_PAL_side1_DS4_pp_2019-10-14_18-50-10.raw.oga /mnt/md0/Decodes/autoAIV/NationalA/simonds4_nationalA $STANDARD --start 385 $TESTSWITCH ; fi
if [ "$NATIONALB" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS4/Domesday\ National_CLV_PAL_side2_DS4_2019-10-14_19-28-13.raw.oga /mnt/md0/Decodes/autoAIV/NationalB/simonds4_nationalB $STANDARD --start 217 $TESTSWITCH ; fi
if [ "$COMMN" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS4/Domesday\ Community_CAV_PAL_side1_North\ DS4_2019-10-14_20-43-35.raw.oga /mnt/md0/Decodes/autoAIV/CommunityN/simonds4_commN $STANDARD --start 347 $TESTSWITCH ; fi
if [ "$COMMS" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS4/Domesday\ Community_CAV_PAL_side2_South\ DS4_2019-10-14_21-21-20.raw.oga /mnt/md0/Decodes/autoAIV/CommunityS/simonds4_commS $STANDARD --start 350 $TESTSWITCH ; fi

# Simon DS5
echo "Decoding Simon DS5..."
if [ "$NATIONALA" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS5/Domesday\ National_CAV_PAL_side1_DS5_ask_2019-11-11_14-46-10.raw.oga /mnt/md0/Decodes/autoAIV/NationalA/simonds5_nationalA $STANDARD --start 306 $TESTSWITCH ; fi
if [ "$NATIONALB" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS5/Domesday\ National_CLV_PAL_side2_DS5_ask_2019-11-11_15-23-37.raw.oga /mnt/md0/Decodes/autoAIV/NationalB/simonds5_nationalB $STANDARD --start 206 $TESTSWITCH ; fi
if [ "$COMMN" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS5/Domesday\ Community_CAV_PAL_side1_North\ DS5_2019-11-11_16-36-02.raw.oga /mnt/md0/Decodes/autoAIV/CommunityN/simonds5_commN $STANDARD --start 295 $TESTSWITCH ; fi
if [ "$COMMS" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/Domesday\ DS5/Domesday\ Community_CAV_PAL_side2_South\ DS5_2019-11-11_17-14-53.raw.oga /mnt/md0/Decodes/autoAIV/CommunityS/simonds5_commS $STANDARD --start 318 $TESTSWITCH ; fi

# Ian DS1
echo "Decoding Ian DS1..."
if [ "$NATIONALA" = "true" ]; then ld-decode /mnt/md0/SFTP/iansmallshire/Banana1/AIV/Domesday_DS1_NoPP/DD_National_A_CAV_PAL_side1_2020-01-02_12-52-22.ldf /mnt/md0/Decodes/autoAIV/NationalA/iands1_nationalA $STANDARD --start 363 $TESTSWITCH ; fi
if [ "$NATIONALB" = "true" ]; then ld-decode /mnt/md0/SFTP/iansmallshire/Banana1/AIV/Domesday_DS1_NoPP/DD_National_B_CLV_PAL_side2_ErrorsAt38m_42m_2020-01-02_15-40-33.ldf /mnt/md0/Decodes/autoAIV/NationalB/iands1_nationalB $STANDARD --start 283 $TESTSWITCH ; fi
if [ "$COMMN" = "true" ]; then ld-decode /mnt/md0/SFTP/iansmallshire/Banana1/AIV/Domesday_DS1_NoPP/DD_CommunityNorth_CAV_PAL_side1_2020-01-03_14-00-55.ldf /mnt/md0/Decodes/autoAIV/CommunityN/iands1_commN $STANDARD --start 313 $TESTSWITCH ; fi
if [ "$COMMS" = "true" ]; then ld-decode /mnt/md0/SFTP/iansmallshire/Banana1/AIV/Domesday_DS1_NoPP/DD_CommunitySouth_CAV_PAL_side1_2020-01-03_14-46-06.ldf /mnt/md0/Decodes/autoAIV/CommunityS/iands1_commS $STANDARD --start 312 $TESTSWITCH ; fi

# Ian DS2
echo "Decoding Ian DS2..."
if [ "$NATIONALA" = "true" ]; then ld-decode /mnt/md0/SFTP/iansmallshire/Banana1/AIV/Domesday_DS2_PP/DD_National_A_CAV_PAL_PlusPlus_2020-01-01_09-02-19.ldf /mnt/md0/Decodes/autoAIV/NationalA/iands2_nationalA $STANDARD --start 354 $TESTSWITCH ; fi
if [ "$NATIONALB" = "true" ]; then ld-decode /mnt/md0/SFTP/iansmallshire/Banana1/AIV/Domesday_DS2_PP/DD_National_B_CAV_PAL_side2_2020-01-02_10-04-54.ldf /mnt/md0/Decodes/autoAIV/NationalB/iands2_nationalB $STANDARD --start 206 $TESTSWITCH ; fi
if [ "$COMMN" = "true" ]; then ld-decode /mnt/md0/SFTP/iansmallshire/Banana1/AIV/Domesday_DS2_PP/DD_CommunityNorth_CAV_PAL_PlusPlus_2020-01-01_09-59-35.ldf /mnt/md0/Decodes/autoAIV/CommunityN/iands2_commN $STANDARD --start 316 $TESTSWITCH ; fi
if [ "$COMMS" = "true" ]; then ld-decode /mnt/md0/SFTP/iansmallshire/Banana1/AIV/Domesday_DS2_PP/DD_CommunitySouth_CAV_PAL_PlusPlus_2020-01-01_10-36-50.ldf /mnt/md0/Decodes/autoAIV/CommunityS/iands2_commS $STANDARD --start 308 $TESTSWITCH ; fi

# Ian DS3
echo "Decoding Ian DS3..."
if [ "$NATIONALA" = "true" ]; then ld-decode /mnt/md0/SFTP/iansmallshire/Banana1/AIV/Domesday_DS3_NoPP/DD_National_A_CAV_PAL_side1_2020-01-03_08-15-24.ldf /mnt/md0/Decodes/autoAIV/NationalA/iands3_nationalA $STANDARD --start 237 $TESTSWITCH ; fi
if [ "$NATIONALB" = "true" ]; then ld-decode /mnt/md0/SFTP/iansmallshire/Banana1/AIV/Domesday_DS3_NoPP/DD_National_B_CLV_PAL_side2_ErrorsAt32m_50m_55m_59m_2020-01-02_17-51-46.ldf /mnt/md0/Decodes/autoAIV/NationalB/iands3_nationalB $STANDARD --start 101 $TESTSWITCH ; fi
if [ "$COMMN" = "true" ]; then ld-decode /mnt/md0/SFTP/iansmallshire/Banana1/AIV/Domesday_DS3_NoPP/DD_CommunityNorth_CAV_PAL_side1_2020-01-03_08-52-16.ldf /mnt/md0/Decodes/autoAIV/CommunityN/iands3_commN $STANDARD --start 325 $TESTSWITCH ; fi
if [ "$COMMS" = "true" ]; then ld-decode /mnt/md0/SFTP/iansmallshire/Banana1/AIV/Domesday_DS3_NoPP/DD_CommunitySouth_CAV_PAL_side1_2020-01-03_09-33-51.ldf /mnt/md0/Decodes/autoAIV/CommunityS/iands3_commS $STANDARD --start 310 $TESTSWITCH ; fi

# Stephen DS1
echo "Decoding Stephen DS1..."
if [ "$NATIONALA" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/StephenNeal/Domesday\ National_CAV_PAL_side1_SNpp_DS1_2020-02-15_12-04-34.ldf /mnt/md0/Decodes/autoAIV/NationalA/stephends1_nationalA $STANDARD --start 326 $TESTSWITCH ; fi
if [ "$NATIONALB" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/StephenNeal/Domesday\ National_CLV_PAL_side2_SN_DS1_44minonly_2020-02-15_14-39-36.ldf /mnt/md0/Decodes/autoAIV/NationalB/stephends1_nationalB $STANDARD --start 203 $TESTSWITCH ; fi
if [ "$COMMN" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/StephenNeal/Domesday\ Community_CAV_PAL_side1_SN_North_2020-02-15_15-43-58.ldf /mnt/md0/Decodes/autoAIV/CommunityN/stephends1_commN $STANDARD --start 325 $TESTSWITCH ; fi
if [ "$COMMS" = "true" ]; then ld-decode /mnt/md0/SFTP/simoninns/LDV4300D_1\ Captures/AIV/StephenNeal/Domesday\ Community_CAV_PAL_side2_SN_South_2020-02-15_16-22-27.ldf /mnt/md0/Decodes/autoAIV/CommunityS/stephends1_commS $STANDARD --start 302 $TESTSWITCH ; fi


