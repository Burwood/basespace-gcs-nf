// main.nf
nextflow.enable.dsl=2

/*
 * This channel will hold the BaseSpace file ID and the desired output file name.
 * In a real pipeline, this channel would be populated by a previous process
 * that queries the BaseSpace API.
 * * Format: [basespace_file_id, gcs_output_path]
 */
workflow {
    Channel
        .of(
            [ '42274677162', 'gs://a-test-output/2025WW01450_S8_L001_R1_001.fastq.gz' ],
            [ '42274677163', 'gs://a-test-output/2025WW01450_S8_L001_R2_001.fastq.gz ' ]
        )
        .set { bs_files_ch }

    // Execute the transfer process for each file
    TRANSFER_BS_TO_GCS(bs_files_ch)
}

process TRANSFER_BS_TO_GCS {
    // We assume the Docker container has 'bs' and 'gcloud' installed
    container 'us-central1-docker.pkg.dev/asu-ap-gap-data-opstest-18c2/bs-gcs/client:latest'
    
    input:
    tuple val(bs_file_id), val(gcs_output_uri)

    output:
    val gcs_output_uri, emit: gcs_path

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
    echo "Uploading \$local_filename to $gcs_output_uri..."

    # Use gsutil (part of gcloud) to perform the copy
    gsutil cp "\$local_filename" "$gcs_output_uri"

    if [ \$? -ne 0 ]; then
        echo "Error: GCS upload failed for $gcs_output_uri."
        exit 1
    fi

    echo "Transfer complete for $bs_file_id to $gcs_output_uri."
    """
}