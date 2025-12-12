// main.nf
nextflow.enable.dsl=2

params.input_files = null
params.outdir = null

workflow {

    if (!params.input_files) {
        error "Input files are required.  Please specify"
    }

    if (!params.outdir) {
        error "Out directory is required.  Please specify"
    }

    log.info "Files to copy from Basespace Sequence Hub : ${params.input_files}"
    log.info "Out directory: ${params.outdir}"

    channel.fromList(params.input_files).set { bs_files_ch }

    // Execute the transfer process for each file
    TRANSFER_BS_TO_GCS(bs_files_ch)
}

process TRANSFER_BS_TO_GCS {
    // Docker container that has 'bs' and 'gcloud' installed
    container 'us-central1-docker.pkg.dev/asu-ap-gap-data-opstest-18c2/bs-gcs/client:latest'
    
    input:
    val (bs_file_id)

    output:
    val params.outdir, emit: gcs_path

    script:
    """
    # 1. Download the file from BaseSpace using the BaseSpace CLI.
    # The 'bs download' command is used, which places the file in the current directory.
    # We use '--output ./' to ensure it's in the process's working directory.
    echo "Downloading file $bs_file_id from BaseSpace..."
    
    # Get the file name from the BaseSpace metadata
    local_filename=\$(bs file get -i $bs_file_id --template '{{.Name}}')

    # Download the file
    bs download file -i $bs_file_id --output ./

    if [ ! -f "\$local_filename" ]; then
        echo "Error: BaseSpace file download failed for $bs_file_id."
        exit 1
    fi

    # 2. Upload the file to Google Cloud Storage.
    echo "Uploading \$local_filename to ${params.outdir}"

    # Use gsutil (part of gcloud) to perform the copy
    gsutil cp "\$local_filename" "${params.outdir}/\$local_filename"

    if [ \$? -ne 0 ]; then
        echo "Error: GCS upload failed for ${params.outdir}."
        exit 1
    fi

    echo "Transfer complete for $bs_file_id to ${params.outdir}."
    """
}