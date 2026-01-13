//
//  PromptRenderer.swift
//  DrsMainApp
//
//  Created by Nathanael on 1/13/26.
//

import Foundation

struct PromptRenderer {

    static func render(_ template: String,
                       problemListing: String,
                       vaccinationStatus: String,
                       pmh: String,
                       priorDx: String,
                       question: String?) -> String {

        let clinicalQuestion: String = {
            let trimmed = (question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "What is the most likely diagnosis and next steps for this child?"
                : trimmed
        }()

        // Simple placeholder replacement
        return template
            .replacingOccurrences(of: "{problem_listing}", with: problemListing)
            .replacingOccurrences(of: "{vaccination_status}", with: vaccinationStatus)
            .replacingOccurrences(of: "{pmh}", with: pmh)
            .replacingOccurrences(of: "{prior_dx}", with: priorDx)
            .replacingOccurrences(of: "{clinical_question}", with: clinicalQuestion)
    }
}
