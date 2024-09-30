/**
 * Copyright 2022 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/******************************************
1. Local variables declaration
*******************************************/

locals {
project_id                  = "${var.project_id}"
location                    = "${var.location}"
gcs_bucket                  = "gcs-bucket-${var.project_nbr}"
dataset_name                = "icecream_dataset"
}

provider "google" {
  project = local.project_id
  region  = local.location
}

/******************************************
1. Creation of IAM groups
*******************************************/

resource "null_resource" "create_groups" {
   for_each = {
      "us-sales" : "",
      "australia-sales" : ""
    }
  provisioner "local-exec" {
    command = <<-EOT
      thegroup=`gcloud identity groups describe ${each.key}@${var.org_id}  | grep -i "id:"  | cut -d':' -f2 |xargs`
      #create group if it doesn't exist
      if [ -z "$thegroup" ]; then
        gcloud identity groups create ${each.key}@${var.org_id} --organization="${var.org_id}" --group-type="security" 
      fi
    EOT
  }

}

resource "time_sleep" "wait_30_seconds" {

  create_duration = "30s"
  
  depends_on = [
    null_resource.create_groups
    ]

}

/******************************************
2. Creation of IAM group memberships to the sales groups for the sales users
*******************************************/
    
resource "null_resource" "create_memberships" {
   for_each = {
      "us-sales" : format("%s",var.usa_username),
      "us-sales" : format("%s",var.super_username),
      "australia-sales" : format("%s",var.aus_username)
      "australia-sales" : format("%s",var.super_username)
    }
  provisioner "local-exec" {
    command = <<-EOT
      thegroup=`gcloud identity groups memberships list --group-email="${each.key}@${var.org_id}" | grep -i "id:"  | cut -d':' -f2 |xargs`
      #add member if not already a member
      if ! [[ "$thegroup" == *"${each.value}"* ]]; 
      then   
        gcloud identity groups memberships add --group-email="${each.key}@${var.org_id}" --member-email="${each.value}@${var.org_id}" 
      fi
    EOT
  }

  depends_on = [
    time_sleep.wait_30_seconds
  ]

}

/******************************************
3. Creation of IAM group membership to the sales groups for the marketing user
*******************************************/
resource "null_resource" "create_memberships_mkt" {
   for_each = {
      "us-sales" : format("%s",var.mkt_username),
      "australia-sales" : format("%s",var.mkt_username)
    }
  provisioner "local-exec" {
    command = <<-EOT
      thegroup=`gcloud identity groups memberships list --group-email="${each.key}@${var.org_id}" | grep -i "id:"  | cut -d':' -f2 |xargs`
      #add member if not already a member
      if ! [[ "$thegroup" == *"${each.value}"* ]]; 
      then   
        gcloud identity groups memberships add --group-email="${each.key}@${var.org_id}" --member-email="${each.value}@${var.org_id}" 
      fi
    EOT
  }

  depends_on = [
    null_resource.create_memberships
  ]

}

/******************************************
4. Project Viewer permissions granting for all users
*******************************************/
  
resource "google_project_iam_binding" "project_viewer" {
  project = var.project_id
  role    = "roles/viewer"

  members = [
    "user:${var.usa_username}@${var.org_id}",
    "user:${var.aus_username}@${var.org_id}",
    "user:${var.mkt_username}@${var.org_id}"
  ]
}
  
/******************************************
5. Create GCS bucket
*******************************************/

resource "google_storage_bucket" "create_gcs_bucket" {

  name                              = local.gcs_bucket
  location                          = local.location
  uniform_bucket_level_access       = true
  force_destroy                     = true

}
  
/******************************************
6. IceCreamSales.csv dataset upload to each user bucket 
*******************************************/

resource "google_storage_bucket_object" "gcs_objects" {
  name        = "data/IceCreamSales.csv"
  source      = "./resources/IceCreamSales.csv"
  bucket      = "${local.gcs_bucket}"
  depends_on = [google_storage_bucket.create_gcs_bucket]
}
  


/******************************************
# 7. Creation of Data Catalog Taxonomy with policy type of "FINE_GRAINED_ACCESS_CONTROL"
*******************************************/

resource "google_data_catalog_taxonomy" "business_critical_taxonomy" {
  project  = var.project_id
  region   = var.location
  # Must be unique accross your Org
  display_name           = "Business-Critical-${var.project_nbr}"
  description            = "A collection of policy tags"
  activated_policy_types = ["FINE_GRAINED_ACCESS_CONTROL"]
}
  
/******************************************
# 8. Creation of Data Catalog policy tag tied to the taxonomy
*******************************************/

resource "google_data_catalog_policy_tag" "financial_data_policy_tag" {
  taxonomy     = google_data_catalog_taxonomy.business_critical_taxonomy.id
  display_name = "Financial Data"
  description  = "A policy tag normally associated with low security items"

  depends_on = [
    google_data_catalog_taxonomy.business_critical_taxonomy,
  ]
}

/******************************************
# 9. Granting of fine grained reader permisions to us_user@ and aus_user@
*******************************************/
resource "google_data_catalog_policy_tag_iam_member" "member" {
  for_each = {
    "user:${var.aus_username}@${var.org_id}" : "",
    "user:${var.usa_username}@${var.org_id}" : "",
    "user:${var.super_username}@${var.org_id}" : ""
  }
  policy_tag = google_data_catalog_policy_tag.financial_data_policy_tag.name
  role       = "roles/datacatalog.categoryFineGrainedReader"
  member     = each.key
  depends_on = [
    google_data_catalog_policy_tag.financial_data_policy_tag,
  ]
}

/******************************************
# 10. Creation of BigQuery dataset
*******************************************/

resource "google_bigquery_dataset" "bigquery_dataset" {
  dataset_id                  = local.dataset_name
  friendly_name               = local.dataset_name
  description                 = "Dataset for BigLake Demo"
  location                    = var.location
  delete_contents_on_destroy  = true

  depends_on = [google_storage_bucket_object.gcs_objects]
}


/******************************************
# 11. Creation of BigQuery table
*******************************************/
resource "google_bigquery_table" "bqTable" {
    ## If you are using schema autodetect, uncomment the following to
    ## set up a dependency on the prior delay.
    # depends_on = [time_sleep.wait_7_min]
    dataset_id = google_bigquery_dataset.bigquery_dataset.dataset_id
    table_id   = "IceCreamSales"
    project = var.project_id
    schema = <<EOF
    [
            {
                "name": "country",
                "type": "STRING"
            },
            {
                "name": "month",
                "type": "DATE"
                },
            {
                "name": "Gross_Revenue",
                "type": "FLOAT"
            },
            {
                "name": "Discount",
                "type": "FLOAT",
                "policyTags": {
                  "names": [
                    "${google_data_catalog_policy_tag.financial_data_policy_tag.id}"
                    ]
                }
            },
            {
                "name": "Net_Revenue",
                "type": "FLOAT",
                "policyTags": {
                  "names": [
                    "${google_data_catalog_policy_tag.financial_data_policy_tag.id}"
                    ]
                }
            }
    ]
    EOF
    deletion_protection = false
    depends_on = [
              google_storage_bucket_object.gcs_objects,
              google_data_catalog_policy_tag_iam_member.member,
              google_bigquery_dataset.bigquery_dataset
              ]
}

/******************************************
# 12. Load BigQuery table
*******************************************/
resource "google_bigquery_job" "job" {
  job_id     = "job_load"

  labels = {
    "my_job" ="load"
  }
  location                    = var.location

  load {
    source_uris = [
      "gs://${local.gcs_bucket}/data/IceCreamSales.csv",
    ]

    destination_table {
      project_id = var.project_id
      dataset_id = google_bigquery_table.bqTable.dataset_id
      table_id   = google_bigquery_table.bqTable.table_id
    }

    skip_leading_rows = 1
    write_disposition = "WRITE_TRUNCATE"
  }

  depends_on = [google_bigquery_table.bqTable]
}

/******************************************
# 13. Creation of Row Access Policy for Australia
*******************************************/
resource "null_resource" "create_aus_filter" {
  provisioner "local-exec" {
    command = <<-EOT
      read -r -d '' QUERY << EOQ
      CREATE ROW ACCESS POLICY
        Australia_filter
        ON
        ${local.dataset_name}.IceCreamSales
        GRANT TO
        ("group:australia-sales@${var.org_id}")
        FILTER USING
        (Country="Australia")
      EOQ
      bq query --nouse_legacy_sql $QUERY
    EOT
  }

  depends_on = [google_bigquery_table.bqTable]
}

/******************************************
# 14. Creation of Row Access Policy for United States
*******************************************/
resource "null_resource" "create_us_filter" {
  provisioner "local-exec" {
    command = <<-EOT
      read -r -d '' QUERY << EOQ
      CREATE ROW ACCESS POLICY
        US_filter
        ON
        ${local.dataset_name}.IceCreamSales
        GRANT TO
        ("group:us-sales@${var.org_id}")
        FILTER USING
        (Country="United States")
      EOQ
      bq query --nouse_legacy_sql $QUERY
    EOT
  }

  depends_on = [null_resource.create_aus_filter]
}
