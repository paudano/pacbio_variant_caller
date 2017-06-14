"""
Called by genotype.snakefile to map sample reads and perform post-alt processing on the alignments. The
output BAM file aligns reads to the primary contigs (reference the SVs were called against) and alternate contigs
(local assemblies the SVs were found on).
"""

import pandas as pd
import socket


###################
### Definitions ###
###################

# Get parameters
SAMPLE = config['sample']                    # Sample name
SAMPLE_BAM = config['sample_bam']            # BAM file of sample reads (mapped and unmapped reads).
SAMPLE_REF = config['sample_ref']            # Reference sample reads are mapped to.
SAMPLE_REF_FAI = SAMPLE_REF + '.fai'         # Sample reference FASTA index.
SAMPLE_REGIONS = config['sample_regions']    # BED file describing where mapped reads in the sample BAM should be extracted from.
SV_REF = config['sv_ref']                    # Augmented reference with local assemblies as alternate contigs.
SV_REF_ALT_INFO = config['sv_ref_alt_info']  # BED file of all contigs. Gives lengths, whether or not they are primary, and which primary contig the alternates belong to.
CONTIG_BAM = config['contig_bam']            # BAM file of local-assembly contigs aligned to the reference.
OUTPUT_BAM = config['output_bam']            # Output BAM file with reads mapped to the primary contigs and alternate contigs.
OUTPUT_BAI = OUTPUT_BAM + '.bai'             # Output BAM file index.

THREADS = config['threads']                  # Number of alignment threads
MAPQ = config['mapq']                        # Minimum mapping quality of reads once re-aligned to the augmented reference.
MAPPING_TEMP = config['mapping_temp']        # Directory where local temporary files are located.
SMRTSV_DIR = config['smrtsv_dir']            # Directory where SMRTSV is installed.
POSTALT_PATH = config['postalt_path']        # Full path to bwa-postalt.js

# Read alternate info BED and primary contig names
ALT_BED = pd.read_table(SV_REF_ALT_INFO, header=0)
ALT_BED.index = ALT_BED['#CHROM']

# Get list of primary contigs (reference assembly without local assembly contigs).
PRIMARY_CONTIG_LIST = sorted(ALT_BED.loc[ALT_BED['IS_PRIMARY']]['#CHROM'].tolist())

# Set primary BAM location (initial alignment before post-alt processing).
PRIMARY_BAM = os.path.join(MAPPING_TEMP, 'primary.bam')

# Create subdirectories of the temp directories
PRIMARY_TEMP = os.path.join(MAPPING_TEMP, 'primary')
POSTALT_TEMP = os.path.join(MAPPING_TEMP, 'postalt')

os.makedirs(PRIMARY_TEMP, exist_ok=True)
os.makedirs(os.path.join(POSTALT_TEMP, 'bam', 'temp'), exist_ok=True)

# Setup filename patterns to avoid re-computing them in the rules.
FILE_CONTIG_BED = POSTALT_TEMP + '/{primary_contig}.bed'
FILE_CONTIG_ALT = POSTALT_TEMP + '/{primary_contig}.alt'
FILE_CONTIG_BAM = POSTALT_TEMP + '/bam/{primary_contig}.bam'

# Get hostname
HOSTNAME = socket.gethostname()


#############
### Rules ###
#############

# gt_map_postalt_merge
#
# Merge alignments for each primary contig.
rule gt_map_postalt_merge:
    input:
        bam=expand(FILE_CONTIG_BAM, primary_contig=PRIMARY_CONTIG_LIST)
    output:
        bam=OUTPUT_BAM,
        bai=OUTPUT_BAI
    run:

        print('Merging {} postalt processed BAM files'.format(len(input.bam)))

        shell(
            """samtools merge {output.bam} {input.bam}; """
            """samtools index {output.bam}"""
        )

# gt_map_postalt_realign
#
# Remap reads to alternate contigs for one primary contig and adjust quality scores.
rule gt_map_postalt_remap:
    input:
        bam=PRIMARY_BAM,
        alt=FILE_CONTIG_ALT,
        bed=FILE_CONTIG_BED
    output:
        bam=FILE_CONTIG_BAM
    shell:
        """echo "Post-ALT processing {wildcards.primary_contig}"; """
        """samtools view -hL {input.bed} {input.bam} | """
        """k8 {POSTALT_PATH} {input.alt} | """
        """samtools view -hq {MAPQ} | """
        """samtools sort -T {POSTALT_TEMP}/bam/temp/{wildcards.primary_contig} -O bam -o {output.bam}; """

# gt_map_postalt_alt_sam
#
# Get a SAM file (as .alt) of the alternate contigs of one primary contig.
rule gt_map_postalt_alt_sam:
    input:
        bed=FILE_CONTIG_BED,
        primary_bam=PRIMARY_BAM
    output:
        alt=temp(FILE_CONTIG_ALT)
    shell:
        """samtools view -hL {input.bed} {CONTIG_BAM} >{output.alt}"""

# gt_map_postalt_contig_bed
#
# Get a BED file covering a primary contig and all its alternate contigs.
rule gt_map_postalt_contig_bed:
    input:
        primary_bam=PRIMARY_BAM
    output:
        bed=temp(FILE_CONTIG_BED)
    run:
        ALT_BED.loc[ALT_BED['PRIMARY'] == wildcards.primary_contig].to_csv(
            output.bed, sep='\t', header=True, index=False
        )

# gt_map_primary_alignment
#
# Map reads to the augmented reference (primary + local-assembly-contigs).
rule gt_map_primary_alignment:
    output:
        primary_bam=PRIMARY_BAM
    log:
        'log/primary_alignment.log'.format(SAMPLE)
    shell:
        """echo "Running primary alignment for sample {SAMPLE}"; """
        """echo "Input BAM: {SAMPLE_BAM}"; """
        """echo "Input BAM reference: {SAMPLE_REF}"; """
        """echo "Log: {log}"; """
        """echo "Temp: {MAPPING_TEMP}"; """
        """echo "Host: {HOSTNAME}"; """
        """>{log}; """
        """{{ \n"""
        """    while read line; \n"""
        """        do set -- $line; \n"""
        """        samtools view {SAMPLE_BAM} $1:$2-$3; \n"""
        """    done <{SAMPLE_REGIONS} | \n"""
        """    samtools view -S -t {SAMPLE_REF_FAI} -u -b - 2>>{log} | \n"""
        """    samtools collate -n 32 -O - {PRIMARY_TEMP}/primary_bam 2>>{log} | \n"""
        """    samtools bam2fq - 2>>{log} | \n"""
        """    seqtk dropse - 2>>{log}; \n"""
        """    samtools view {SAMPLE_BAM} '*' 2>>{log} | \n"""
        """    samtools bam2fq - 2>>{log} | \n"""
        """    python {SMRTSV_DIR}/scripts/genotype/FilterFastqHardmask.py --max_mask_prop=0.05 /dev/stdin 2>>{log} | \n"""
        """    seqtk dropse - 2>>{log}; \n"""
        """}} | """
        """bwa mem -R '@RG\\tID:{SAMPLE}\\tSM:{SAMPLE}' -p -t {THREADS} {SV_REF} - 2>>{log} | """
        """samblaster --removeDups 2>>{log} | """
        """samtools view -b 2>>{log} """
        """>{output.primary_bam}"""