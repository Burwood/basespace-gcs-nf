// main.nf
nextflow.enable.dsl=2

// Parameters for Secret Manager configuration
params.basespace_secret_name = 'basespace-api-key'
params.gcp_project = 'asu-ap-gap-data-opstest-18c2'

/*
 * This channel will hold the BaseSpace file ID and the desired output file name.
 * In a real pipeline, this channel would be populated by a previous process
 * that queries the BaseSpace API.
 * Format: [basespace_file_id, gcs_output_path]
 */
workflow {
    Channel
        .of(
            [ '42274677162', 'gs://a-test-output/2025WW01450_S8_L001_R1_001.fastq.gz' ],
            [ '42274677163', 'gs://a-test-output/2025WW01450_S8_L001_R2_001.fastq.gz' ]
        )
        .set { bs_files_ch }

    // Execute the transfer process for each file
    TRANSFER_BS_TO_GCS(bs_files_ch)
}

process TRANSFER_BS_TO_GCS {
    // Docker container with BaseSpace CLI and Google Cloud SDK
    container 'us-central1-docker.pkg.dev/asu-ap-gap-data-opstest-18c2/bs-gcs2/client:latest'
    
    input:
    tuple val(bs_file_id), val(gcs_output_uri)

    output:
    val gcs_output_uri, emit: gcs_path

    script:
    """
    set -x  # Print commands as they execute (for debugging)
    
    echo "=========================================="
    echo "Starting BaseSpace to GCS Transfer Process"
    echo "=========================================="
    echo "Timestamp: \$(date)"
    echo "Working directory: \$(pwd)"
    echo "User: \$(whoami)"
    echo ""
    
    # Log environment information
    echo "=== Environment Information ==="
    echo "PATH: \$PATH"
    echo "HOME: \$HOME"
    echo "PWD: \$(pwd)"
    echo ""
    
    # Check required tools are available
    echo "=== Checking Required Tools ==="
    if ! command -v gcloud &> /dev/null; then
        echo "ERROR: gcloud command not found!"
        echo "PATH: \$PATH"
        exit 1
    fi
    echo "✓ gcloud found: \$(gcloud --version | head -n1)"
    
    if ! command -v bs &> /dev/null; then
        echo "ERROR: bs (BaseSpace CLI) command not found!"
        exit 1
    fi
    echo "✓ bs found: \$(bs --version 2>&1 | head -n1)"
    
    if ! command -v gsutil &> /dev/null; then
        echo "ERROR: gsutil command not found!"
        exit 1
    fi
    echo "✓ gsutil found: \$(gsutil version 2>&1 | head -n1)"
    echo ""
    
    # Check GCP authentication
    echo "=== Checking GCP Authentication ==="
    echo "Configuring gcloud to use Application Default Credentials..."
    
    # In compute environments, use Application Default Credentials (ADC)
    # Set the project explicitly
    gcloud config set project "${params.gcp_project}" 2>&1 || true
    
    # Verify ADC is available
    echo "Testing Application Default Credentials..."
    if ! gcloud auth application-default print-access-token &> /dev/null; then
        echo "WARNING: Application Default Credentials not available"
        echo "Attempting to use service account from metadata server..."
        
        # Try to get service account from metadata server (GCP compute environments)
        SERVICE_ACCOUNT=\$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email 2>/dev/null || echo "")
        
        if [ -n "\$SERVICE_ACCOUNT" ]; then
            echo "✓ Found service account from metadata: \$SERVICE_ACCOUNT"
            echo "Using service account authentication..."
        else
            echo "ERROR: No GCP authentication available"
            echo "This compute environment may not have a service account configured"
            exit 1
        fi
    else
        echo "✓ Application Default Credentials available"
        # Get the account being used
        ACTIVE_ACCOUNT=\$(gcloud auth application-default print-access-token 2>&1 | head -n1 || echo "ADC")
        echo "Using Application Default Credentials"
    fi
    echo ""
    
    # Retrieve BaseSpace API key from Google Secret Manager
    echo "=== Retrieving BaseSpace API Key from Secret Manager ==="
    echo "Secret name: ${params.basespace_secret_name}"
    echo "Project: ${params.gcp_project}"
    echo ""
    
    # First, test if we can access the secret (without capturing output)
    echo "Testing secret access..."
    if ! gcloud secrets describe "${params.basespace_secret_name}" --project="${params.gcp_project}" &> /dev/null; then
        echo "ERROR: Cannot access secret '${params.basespace_secret_name}'"
        echo ""
        echo "Troubleshooting information:"
        echo "- Project: ${params.gcp_project}"
        echo "- Secret name: ${params.basespace_secret_name}"
        echo ""
        echo "Attempting to list available secrets (to verify permissions)..."
        gcloud secrets list --project="${params.gcp_project}" 2>&1 || {
            echo "Cannot list secrets - this indicates a permission issue"
            echo "Please ensure the compute environment's service account has:"
            echo "  - roles/secretmanager.secretAccessor (for the specific secret)"
            echo "  - roles/secretmanager.viewer (to list secrets)"
        }
        exit 1
    fi
    echo "✓ Secret exists and is accessible"
    echo ""
    
    # Now retrieve the secret value
    echo "Retrieving secret value..."
    SECRET_OUTPUT=\$(gcloud secrets versions access latest \
        --secret="${params.basespace_secret_name}" \
        --project="${params.gcp_project}" 2>&1)
    SECRET_EXIT_CODE=\$?
    
    echo "gcloud command exit code: \$SECRET_EXIT_CODE"
    echo "Secret output length: \${#SECRET_OUTPUT} characters"
    
    if [ \$SECRET_EXIT_CODE -ne 0 ]; then
        echo "ERROR: Failed to retrieve secret (exit code: \$SECRET_EXIT_CODE)"
        echo "Error output:"
        echo "\$SECRET_OUTPUT"
        echo ""
        echo "Debugging information:"
        echo "Current service account (from metadata server):"
        curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email 2>&1 || echo "Not available via metadata server"
        echo ""
        echo "Project configuration:"
        gcloud config get-value project 2>&1 || echo "No project configured"
        echo ""
        echo "Application Default Credentials status:"
        gcloud auth application-default print-access-token &> /dev/null && echo "ADC is available" || echo "ADC is not available"
        exit 1
    fi
    
    if [ -z "\$SECRET_OUTPUT" ]; then
        echo "ERROR: Secret retrieval returned empty value"
        echo "This could indicate:"
        echo "  - Secret exists but has no value"
        echo "  - Permission issue reading secret value"
        echo "  - Secret version issue"
        exit 1
    fi
    
    # Clean the secret value (remove leading/trailing whitespace and newlines)
    # Use xargs to trim whitespace (simpler and more reliable)
    BASESPACE_API_KEY=\$(echo "\$SECRET_OUTPUT" | tr -d '\n\r' | xargs)
    echo "✓ Secret retrieved successfully (length: \${#BASESPACE_API_KEY} characters)"
    echo ""
    
    # Validate API key is not empty after cleaning
    if [ -z "\$BASESPACE_API_KEY" ]; then
        echo "ERROR: API key is empty after cleaning"
        echo "Original secret length: \${#SECRET_OUTPUT} characters"
        exit 1
    fi
    
    # Export API key as environment variable (BaseSpace CLI will use it automatically)
    echo "=== Setting BaseSpace API Key ==="
    export BASESPACE_API_KEY="\$BASESPACE_API_KEY"
    # Also set as ACCESS_TOKEN (some CLI versions use this)
    export BASESPACE_ACCESS_TOKEN="\$BASESPACE_API_KEY"
    echo "✓ BASESPACE_API_KEY environment variable set"
    echo "✓ BASESPACE_ACCESS_TOKEN environment variable set (for compatibility)"
    echo "Key length: \${#BASESPACE_API_KEY} characters"
    echo "Key preview (first 10 chars): \${BASESPACE_API_KEY:0:10}..."
    echo ""
    
    # Verify BaseSpace authentication using REST API
    echo "=== Verifying BaseSpace Authentication ==="
    echo "Testing BaseSpace API key with REST API..."
    
    # BaseSpace API requires API key as query parameter, not Bearer token
    # URL encode the API key for safety
    ENCODED_API_KEY=\$(python3 -c "import urllib.parse; print(urllib.parse.quote('\$BASESPACE_API_KEY'))" 2>/dev/null || echo "\$BASESPACE_API_KEY")
    
    # Test authentication by calling the current user endpoint with API key as query parameter
    AUTH_TEST=\$(curl -s -w "\n%{http_code}" \
        "https://api.basespace.illumina.com/v1pre3/users/current?access_token=\$ENCODED_API_KEY" 2>&1)
    HTTP_CODE=\$(echo "\$AUTH_TEST" | tail -n1)
    RESPONSE_BODY=\$(echo "\$AUTH_TEST" | sed '\$d')
    
    if [ "\$HTTP_CODE" != "200" ]; then
        echo "ERROR: BaseSpace authentication failed (HTTP code: \$HTTP_CODE)"
        echo "Response: \$RESPONSE_BODY"
        echo ""
        echo "Debugging information:"
        echo "API key is set: \${BASESPACE_API_KEY:+YES}"
        echo "API key length: \${#BASESPACE_API_KEY} characters"
        echo "API key preview (first 20 chars): \${BASESPACE_API_KEY:0:20}..."
        echo ""
        echo "Please verify:"
        echo "  1. The API key in Secret Manager is valid"
        echo "  2. The API key has not expired"
        echo "  3. The API key has necessary permissions"
        exit 1
    fi
    
    USER_INFO=\$(echo "\$RESPONSE_BODY" | python3 -c "import sys, json; data=json.load(sys.stdin); print(f\"User: {data.get('Response', {}).get('DisplayName', 'Unknown')} (ID: {data.get('Response', {}).get('Id', 'Unknown')})\")" 2>/dev/null || echo "Authentication successful")
    echo "✓ BaseSpace authentication successful"
    echo "\$USER_INFO"
    echo ""
    
    # Download the file from BaseSpace using REST API
    echo "=== BaseSpace File Operations ==="
    echo "BaseSpace file ID: $bs_file_id"
    echo "Target GCS path: $gcs_output_uri"
    echo ""
    
    # Get the file metadata from BaseSpace REST API
    echo "Retrieving file metadata from BaseSpace..."
    FILE_METADATA_RESPONSE=\$(curl -s -w "\n%{http_code}" \
        "https://api.basespace.illumina.com/v1pre3/files/$bs_file_id?access_token=\$ENCODED_API_KEY" 2>&1)
    FILE_HTTP_CODE=\$(echo "\$FILE_METADATA_RESPONSE" | tail -n1)
    FILE_RESPONSE_BODY=\$(echo "\$FILE_METADATA_RESPONSE" | sed '\$d')
    
    if [ "\$FILE_HTTP_CODE" != "200" ]; then
        echo "ERROR: Failed to get file metadata (HTTP code: \$FILE_HTTP_CODE)"
        echo "Response: \$FILE_RESPONSE_BODY"
        echo ""
        echo "The file may not exist or you may not have access to it"
        echo "File ID: $bs_file_id"
        exit 1
    fi
    
    # Extract file name from JSON response
    local_filename=\$(echo "\$FILE_RESPONSE_BODY" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('Response', {}).get('Name', ''))" 2>/dev/null)
    
    if [ -z "\$local_filename" ]; then
        echo "ERROR: File metadata returned empty or invalid"
        echo "Response: \$FILE_RESPONSE_BODY"
        echo "File ID: $bs_file_id"
        exit 1
    fi
    
    echo "✓ File metadata retrieved"
    echo "File name: \$local_filename"
    echo ""
    
    # Get the download URL for the file
    echo "Getting download URL for file..."
    DOWNLOAD_URL_RESPONSE=\$(curl -s -w "\n%{http_code}" \
        "https://api.basespace.illumina.com/v1pre3/files/$bs_file_id/content?access_token=\$ENCODED_API_KEY" 2>&1)
    DOWNLOAD_URL_HTTP_CODE=\$(echo "\$DOWNLOAD_URL_RESPONSE" | tail -n1)
    DOWNLOAD_URL_BODY=\$(echo "\$DOWNLOAD_URL_RESPONSE" | sed '\$d')
    
    if [ "\$DOWNLOAD_URL_HTTP_CODE" != "200" ]; then
        echo "ERROR: Failed to get download URL (HTTP code: \$DOWNLOAD_URL_HTTP_CODE)"
        echo "Response: \$DOWNLOAD_URL_BODY"
        exit 1
    fi
    
    # Extract download URL from JSON response
    DOWNLOAD_URL=\$(echo "\$DOWNLOAD_URL_BODY" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('Response', {}).get('HrefContent', ''))" 2>/dev/null)
    
    if [ -z "\$DOWNLOAD_URL" ]; then
        echo "ERROR: Download URL not found in response"
        echo "Response: \$DOWNLOAD_URL_BODY"
        exit 1
    fi
    
    echo "✓ Download URL retrieved"
    echo ""
    
    # Download the file from BaseSpace
    echo "Downloading file from BaseSpace..."
    echo "File ID: $bs_file_id"
    echo "Output file: \$local_filename"
    echo "Output directory: \$(pwd)"
    
    DOWNLOAD_EXIT=0
    # BaseSpace download URLs typically already include authentication in the signed URL
    # If the URL doesn't have access_token, add it
    if echo "\$DOWNLOAD_URL" | grep -q "access_token"; then
        # URL already has access_token, use as-is
        curl -L -o "\$local_filename" "\$DOWNLOAD_URL" 2>&1 || DOWNLOAD_EXIT=\$?
    else
        # Add access_token to download URL (check if URL already has query params)
        if echo "\$DOWNLOAD_URL" | grep -q "?"; then
            DOWNLOAD_URL_WITH_AUTH="\${DOWNLOAD_URL}&access_token=\$ENCODED_API_KEY"
        else
            DOWNLOAD_URL_WITH_AUTH="\${DOWNLOAD_URL}?access_token=\$ENCODED_API_KEY"
        fi
        curl -L -o "\$local_filename" "\$DOWNLOAD_URL_WITH_AUTH" 2>&1 || DOWNLOAD_EXIT=\$?
    fi
    
    if [ \$DOWNLOAD_EXIT -ne 0 ]; then
        echo "ERROR: BaseSpace file download failed (exit code: \$DOWNLOAD_EXIT)"
        echo "Download URL: \$DOWNLOAD_URL"
        echo "File ID: $bs_file_id"
        echo "Expected filename: \$local_filename"
        exit 1
    fi
    echo "✓ Download completed"
    echo ""
    
    # Verify file was downloaded
    echo "Verifying downloaded file..."
    if [ ! -f "\$local_filename" ]; then
        echo "ERROR: Downloaded file not found"
        echo "Expected file: \$local_filename"
        echo "Current directory: \$(pwd)"
        echo "Files in current directory:"
        ls -la || true
        echo ""
        echo "Checking for similar filenames..."
        find . -name "*\${local_filename##*.}" -type f 2>/dev/null || true
        exit 1
    fi
    
    FILE_SIZE=\$(du -h "\$local_filename" | cut -f1)
    echo "✓ File downloaded successfully"
    echo "File: \$local_filename"
    echo "Size: \$FILE_SIZE"
    echo ""
    
    # Upload the file to Google Cloud Storage
    echo "=== Google Cloud Storage Upload ==="
    echo "Source file: \$local_filename"
    echo "Destination: $gcs_output_uri"
    echo ""
    
    # Verify GCS authentication
    echo "Verifying GCS access..."
    if ! gsutil ls gs:// &> /dev/null; then
        echo "WARNING: Cannot list GCS buckets, but will attempt upload"
    else
        echo "✓ GCS access verified"
    fi
    echo ""
    
    # Use gsutil (part of gcloud) to perform the copy
    echo "Uploading file to GCS..."
    UPLOAD_OUTPUT=\$(gsutil cp "\$local_filename" "$gcs_output_uri" 2>&1)
    UPLOAD_EXIT=\$?
    
    if [ \$UPLOAD_EXIT -ne 0 ]; then
        echo "ERROR: GCS upload failed (exit code: \$UPLOAD_EXIT)"
        echo "Error output:"
        echo "\$UPLOAD_OUTPUT"
        echo ""
        echo "Source file: \$local_filename"
        echo "Destination: $gcs_output_uri"
        echo "File exists: \$([ -f "\$local_filename" ] && echo 'YES' || echo 'NO')"
        exit 1
    fi
    
    echo "✓ Upload completed successfully"
    echo "Upload output: \$UPLOAD_OUTPUT"
    echo ""
    
    echo "=========================================="
    echo "Transfer Complete!"
    echo "=========================================="
    echo "BaseSpace file ID: $bs_file_id"
    echo "Local file: \$local_filename"
    echo "GCS destination: $gcs_output_uri"
    echo "File size: \$FILE_SIZE"
    echo "Timestamp: \$(date)"
    echo ""
    
    # Clean up API key from environment (security best practice)
    unset BASESPACE_API_KEY
    echo "✓ API key cleared from environment"
    """
}