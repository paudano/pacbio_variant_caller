"""
Run assemblies for all windows in a group.
"""

import os
import shutil

if not 'INCLUDE_SNAKEFILE' in globals():
    include: 'include.snakefile'


###################
### Definitions ###
###################

# Get local working directory
LOCAL_ASM_DIR = config.get('local_asm_dir')

os.mkdirs(LOCAL_ASM_DIR, exist_ok=True)

os.chdir(LOCAL_ASM_DIR)


#############
### Rules ###
#############

# assemble_reads
#
# Assemble sequence reads.
rule assemble_reads:
    input:
        fastq='region/{region_id}/reads/reads.fastq'
    output:
        fasta='region/{region_id}/asm/contigs.fasta'
    params:
        threads='4',
        read_length='1000',
        partitions='50',
        max_runtime='10m'
    run:

        # Setup output locations and flag
        assembly_output = 'local/9-terminator/asm.ctg.fasta'
        unitig_output = 'local/9-terminator/asm.utg.fasta'
        assembly_exists = False

        # Run assembly
        try:
            shell(
                """timeout {params.max_runtime} PBcR """
                """-threads {params.threads} """
                """-length {params.read_length} """
                """-partitions {params.partitions} """
                """-l local """
                """-s {CELERA_SPEC} """
                """-fastq {input} """
                """genomeSize={REGION_SIZE} """
                """assembleMinCoverage=5 """
                """&> assembly.log"""
            )
        except:
            shell(
                """echo -e "{REGION}\tassembly_crashed" >> %s""" % config['log']
            )

        # Find assembly and copy to output.
        if os.path.exists(assembly_output) and os.stat(assembly_output).st_size > 0:
            shell(
                """cat {assembly_output} > {output.fasta}; """
                """echo -e "{REGION}\tassembly_exists" >> %s""" % config['log']
            )
            assembly_exists = True

        elif os.path.exists(unitig_output) and os.stat(unitig_output).st_size > 0:
            shell(
                """cat {unitig_output} > {output.fasta}; """ +
                """echo -e "{REGION}\tunitig_assembly_exists" >> %s""" % config['log']
            )
            assembly_exists = True

        else:
            shell("""echo -e "{REGION}\tno_assembly_exists" >> %s""" % config['log'])

        # Create an empty assembly for failed regions.
        if not assembly_exists:
            shell("echo -e '>{REGION}\nN' > {output}")


# convert_reads_to_fasta
#
# Get FASTA and FASTQ file of extracted sequence reads.
rule asm_group_reads_to_fasta:
    input:
        bam='region/{region_id}/reads/reads.bam'
    output:
        fasta='region/{region_id}/reads/reads.fasta',
        fastq='region/{region_id}/reads/reads.fastq'
    shell:
        """echo "### Entering: asm_group_get_region_bam"; """
        """echo "Writing FASTA: {output.fasta}"; """
        """echo "Writing FASTQ: {output.fastq}"; """
        """{SMRTSV_DIR}/scripts/align/BamToFasta.py {input.bam} {output.fasta} --fakename --fastq {output.fastq}"""

# asm_group_get_region_bam
#
# Get reads for one region from the alignment cache (align/reads.bam).
rule asm_group_get_region_bam:
    input:
        bed_can=os.path.join(WORKING_DIR, 'detect/candidates.bed'),
        bam='align/reads.bam',
        bai='align/reads.bam.bai'
    output:
        bam=temp('region/{region_id}/reads/reads.bam'),
        bai=temp('region/{region_id}/reads/reads.bam.bai')
    run:

        print('### Entering: asm_group_get_region_bam')
        print('Getting reads for region {}'.format(wildcards.region_id))

        # Get region
        df_can = pd.read_table(input.bed_can, header=0, index_col='ID')

        if not wildcards.region_id in df_can.index:
            raise RuntimeError('Region ID {} is not in the candidates file {}'.format(wildcards.region_id, input.bed_can))

        region_series = pd.Series(df_can.loc[wildcards.region_id])  # Make a copy so it can be modified
        region_series['POS'] += 1

        region = '{#CHROM}:{POS}-{END}'.format(**region_series)

        # Extract reads
        print('Extracting over region: {}'.format(region))

        shell(
            """samtools view -hb {input.bam} {region} """
            """>{output.bam}; """
            """samtools index {output.bam}"""
        )

# asm_group_get_reads
#
# Cache reads for all regions within this group. When distributed, this makes the pipeline extract reads once from
# shared storage, and each region fetches reads from local storage.
rule asm_group_get_reads:
    input:
        fofn=os.path.join(WORKING_DIR, 'align/alignments.fofn'),
        bed_group=os.path.join(WORKING_DIR, 'detect/candidate_groups.bed')
    output:
        bam='align/reads.bam',
        bai='align/reads.bam.bai'
    params:
        mapq=get_config_param('mapping_quality'),
        group_id = config['group_id']
    run:

        print('### Entering: asm_group_get_reads')
        print('Getting reads for group {}'.format(params.group_id))

        # Read input alignment batches into a list
        bam_file_list = list()

        with open(input.fofn, 'r') as in_file:
            for line in in_file:

                line = line.strip()

                if not line:
                    continue

                bam_file_list.append(line)

        # Get group region
        df_group = pd.read_table(input.bed_group, header=0, index_col='GROUP_ID')

        if not params.group_id in df_group.index:
            raise RuntimeError('Group ID {} is not in the groups file {}'.format(params.group_id, input.bed_group))

        group_series = pd.Series(df_group.loc[params.group_id])  # Make a copy so it can be modified
        group_series['POS'] += 1

        group_region = '{#CHROM}:{POS}-{END}'.format(**group_series)

        print('Extracting over region: {}'.format(group_region))

        # Extract reads
        os.makedirs('align/batch', exist_ok=True)

        try:
            for bam_file in bam_file_list:
                batch_index = os.path.basename(bam_file).rstrip('.bam')

                shell(
                    """echo "Extracting reads from batch {batch_index}..."; """
                    """samtools view -hb -q {params.mapq} {bam_file} {group_region} """
                    """>align/batch/{batch_index}.bam"""
                )

            shell(
                """echo "Merging batches..."; """
                """samtools merge {output.bam} align/batch/*.bam; """
                """samtools index {output.bam}; """
            )

        finally:
            shutil.rmtree('align/batch', ignore_errors=True)




######################################################################################################
######################################################################################################
######                                          OLD CODE                                        ######
######################################################################################################
######################################################################################################


import operator
import os


###################
### Definitions ###
###################

SNAKEMAKE_DIR = os.path.dirname(workflow.snakefile)

# If the user has a config file in the current working directory, use
# that. Otherwise, use SMRT SV defaults.
if os.path.exists("config.json"):
    configfile: "config.json"
else:
    configfile: "%s/../config.template.json" % SNAKEMAKE_DIR

INPUT_READS = config.get("reads", "input.fofn")
CELERA_SPEC = config.get("celera_spec", "%s/../celera/pacbio.local_human.spec" % SNAKEMAKE_DIR)
CHROMOSOME_LENGTHS = config.get("reference_index", "%s.fai" % config["reference"])

## Get a sample .bax.h5 file from the given list of input reads.
#with open(INPUT_READS, "r") as fh:
#    BAS_TEMPLATE = next(fh).strip()

# By default delay jobs for a random amount of time up to this value to prevent
# too much I/O from simultaneous assemblies.
DEFAULT_MAX_DELAY = 1

# User-defined file of alignments with one absolute path to a BAM per line.
ALIGNMENTS = config["alignments"]

# User-defined region in form of "{chrom}-{start}-{end}"
REGION = config["region"]

# Convert filesystem-safe filename of "chrom-start-end" to the more-standard
# region of "chrom:start-end"
STANDARD_REGION = REGION.replace("-", ":", 1)

# Calculate the size of the given region of format "chrom-start-end" by
# splitting the region on "-", selecting the last two elements, reversing their
# order to produce (end, start), converting strings to integers, and applying
# the subtraction operator.
REGION_SIZE = str(operator.sub(*map(int, reversed(REGION.split("-")[1:3]))))


#############
### Rules ###
#############

# align_consensus_to_reference_region
#
# Align assembly to the reference region that was assembled and translate the reference region alignment back to
# reference coordinates.
rule align_consensus_to_reference_region:
    input:
        fa_con='consensus.trimmed.fasta',
        fa_ref='reference_region.fasta'
    output:
        sam='consensus_reference_alignment.sam',
        sam_tmp=temp('consensus_reference_alignment.raw.sam')
    params:
        sge_opts='',
        mapping_quality_threshold=str(config['mapping_quality']),
        asm_alignment_parameters=config['asm_alignment_parameters'].strip('"')  # Parameters are surrounded by quotes to prevent Snakemake from trying to interpret them
    shell:
        """LD_LIBRARY_PATH=/net/eichler/vol18/paudano/pitchfork/20170228/lib:${{LD_LIBRARY_PATH}} """
            """/net/eichler/vol18/paudano/pitchfork/20170228/bin/blasr """
            """{input.fa_con} {input.fa_ref} """
            """--clipping subread """
            """--sam --out {output.sam_tmp} """
            """{params.asm_alignment_parameters}; """
        """samtools view -q {params.mapping_quality_threshold} {output.sam_tmp} | """
        """awk 'OFS="\\t" {{ sub(/:/, "-", $3); num_of_pieces=split($3, pieces, "-"); $3 = pieces[1]; $4 = pieces[2] + $4; print }}' | """
        """sed 's/RG:Z:\w\+\\t//' """
            """> {output.sam}"""

# extract_reference_sequence
#
# extract the reference region that the assembly should be aligned back to.
rule extract_reference_sequence:
    input:
        ref=config['reference'],
        bed='reference_region.bed'
    output:
        fasta=temp('reference_region.fasta')
    params:
        sge_opts=''
    shell:
        """bedtools getfasta -fi {input.ref} -bed {input.bed} -fo {output.fasta}"""

# create_reference_region
#
# Create a BED file that defines the reference region to be extracted from the reference. The assembly is aligned
# to this region.
rule create_reference_region:
    output:
        bed='reference_region.bed'
    params:
        sge_opts=''
    shell:
        """echo {REGION} | sed 's/-/\\t/g' > {output.bed}"""

# trim_consensus
#
# Trim lower-case bases from assembly.
rule trim_consensus:
    input:
        fasta='consensus.fasta'
    output:
        fasta='consensus.trimmed.fasta'
    params:
        sge_opts=''
    shell:
        """{SNAKEMAKE_DIR}/../scripts/trim_lowercase.py --rename_pb {input.fasta} {output.fasta}"""

# arrow_assembly
#
# Polish assembly with arrow.
rule arrow_assembly:
    input:
        assembly='assembly.fasta',
        alignments='alignment.bam',
        assembly_index='assembly.fasta.fai'
    output:
        fasta='consensus.fasta'
    params:
        sge_opts='',
        threads='4'
    run:
        try:
            shell(
                """module load gmp/5.0.2 mpfr/3.1.0 mpc/0.8.2 gcc/4.9.1; """
                """PATH=/net/eichler/vol18/paudano/pitchfork/20170228/bin/:${{PATH}} """
                    """LD_LIBRARY_PATH=/net/eichler/vol18/paudano/pitchfork/20170228/lib:${{LD_LIBRARY_PATH}} """
                    """/net/eichler/vol18/paudano/pitchfork/20170228/bin/pbindex """
                    """{input.alignments}; """
                """PATH=/net/eichler/vol18/paudano/pitchfork/20170228/bin/:${{PATH}} """
                    """LD_LIBRARY_PATH=/net/eichler/vol18/paudano/pitchfork/20170228/lib:${{LD_LIBRARY_PATH}} """
                    """/net/eichler/vol18/paudano/pitchfork/20170228/bin/variantCaller """
                    """--referenceFilename {input.assembly} """
                    """{input.alignments} """
                    """-o {output.fasta} """
                    """--algorithm=arrow; """
                """sed -i 's/^>\(.\+\)/>{REGION}|\\1/' {output.fasta}"""
            )
        except:
            shell(
                """echo -e "{REGION}\tarrow_failed" >> %s""" % config['log'] +
                """cat {input.assembly} > {output.fasta}"""
            )

# map_reads_to_assembly
#
# Map sequence reads to assembly for polishing with arrow.
rule map_reads_to_assembly:
    input:
        bam='reads.bam',
        fasta='assembly.fasta'
    output:
        bam='alignment.bam',
        usort_bam=temp('alignment.usort.bam')
    params:
        sge_opts='',
        threads='4'
    shell:
        try:
            shell(
                """LD_LIBRARY_PATH=/net/eichler/vol18/paudano/pitchfork/20170228/lib:${{LD_LIBRARY_PATH}} """
                    """/net/eichler/vol18/paudano/pitchfork/20170228/bin/blasr """
                    """{input.bam} {input.fasta} """
                    """--bam --bestn 1 """
                    """--unaligned /dev/null """
                    """--out {output.usort_bam} """
                    """--nproc {params.threads}; """
                """samtools sort {output.usort_bam} -o {output.bam}; """
            )

        except:
            print("Mapping reads to assembly crashed, continuing")

            shell(
                """
            )

# index_assembly
#
# Index assembly FASTA.
rule index_assembly:
    input:
        fasta='assembly.fasta'
    output:
        fai='assembly.fasta.fai'
    params:
        sge_opts=''
    shell:
        """samtools faidx {input.fasta}"""

# assemble_reads
#
# Assemble sequence reads.
rule assemble_reads:
    input:
        fastq='reads.fastq'
    output:
        fasta='assembly.fasta'
    params:
        sge_opts='-l mfree=4G -pe serial 2 -l disk_free=10G',
        threads='4',
        read_length='1000',
        partitions='50',
        max_runtime='10m'
    run:

        # Setup output locations and flag
        assembly_output = 'local/9-terminator/asm.ctg.fasta'
        unitig_output = 'local/9-terminator/asm.utg.fasta'
        assembly_exists = False

        # Run assembly
        try:
            shell(
                """timeout {params.max_runtime} PBcR """
                """-threads {params.threads} """
                """-length {params.read_length} """
                """-partitions {params.partitions} """
                """-l local """
                """-s {CELERA_SPEC} """
                """-fastq {input} """
                """genomeSize={REGION_SIZE} """
                """assembleMinCoverage=5 """
                """&> assembly.log"""
            )
        except:
            shell(
                """echo -e "{REGION}\tassembly_crashed" >> %s""" % config['log']
            )

        # Find assembly and copy to output.
        if os.path.exists(assembly_output) and os.stat(assembly_output).st_size > 0:
            shell(
                """cat {assembly_output} > {output.fasta}; """
                """echo -e "{REGION}\tassembly_exists" >> %s""" % config['log']
            )
            assembly_exists = True

        elif os.path.exists(unitig_output) and os.stat(unitig_output).st_size > 0:
            shell(
                """cat {unitig_output} > {output.fasta}; """ +
                """echo -e "{REGION}\tunitig_assembly_exists" >> %s""" % config['log']
            )
            assembly_exists = True

        else:
            shell("""echo -e "{REGION}\tno_assembly_exists" >> %s""" % config['log'])

        # Create an empty assembly for failed regions.
        if not assembly_exists:
            shell("echo -e '>{REGION}\nN' > {output}")
