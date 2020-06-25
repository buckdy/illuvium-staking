/******************************************************************************
 * Copyright © 2013-2016 The Nxt Core Developers.                             *
 * Copyright © 2016-2020 Jelurida IP B.V.                                     *
 *                                                                            *
 * See the LICENSE.txt file at the top-level directory of this distribution   *
 * for licensing information.                                                 *
 *                                                                            *
 * Unless otherwise agreed in a custom licensing agreement with Jelurida B.V.,*
 * no part of this software, including this file, may be copied, modified,    *
 * propagated, or distributed except according to the terms contained in the  *
 * LICENSE.txt file.                                                          *
 *                                                                            *
 * Removal or modification of this copyright notice is prohibited.            *
 *                                                                            *
 ******************************************************************************/

/**
 * @depends {nrs.js}
 */
NRS.onSiteBuildDone().then(() => {
    NRS = (function(NRS, $) {
        
        if (!NRS.isFundingMonitorSupported()) {
            $("#funding_monitor_menu_item").hide();
        }
        if (!NRS.isExternalLinkVisible()) {
            $("#api_console_li").hide();
            $("#database_shell_li").hide();
        }
        if (!NRS.isWebWalletLinkVisible()) {
            $("#web_wallet_li").remove();
        }

        $("#refreshSearchIndex").on("click", function() {
            NRS.sendRequest("luceneReindex", {
                adminPassword: NRS.getAdminPassword()
            }, function (response) {
                if (response.errorCode) {
                    $.growl(NRS.escapeRespStr(response.errorDescription));
                } else {
                    $.growl($.t("search_index_refreshed"));
                }
            })
        });

        $("#header_open_web_wallet").on("click", function() {
            if (java) {
                java.openBrowser(NRS.accountRS);
            }
        });

        $("#client_status_modal").on("show.bs.modal", function() {
            if (NRS.state.isLightClient) {
                $("#client_status_description").text($.t("light_client_description"));
            } else {
                $("#client_status_description").text($.t("api_proxy_description"));
            }
            if (NRS.state.apiProxyPeer) {
                $("#client_status_remote_peer").val(String(NRS.state.apiProxyPeer).escapeHTML());
                $("#client_status_set_peer").prop('disabled', true);
                $("#client_status_blacklist_peer").prop('disabled', false);
            } else {
                $("#client_status_remote_peer").val("");
                $("#client_status_set_peer").prop('disabled', false);
                $("#client_status_blacklist_peer").prop('disabled', true);
            }
            NRS.updateConfirmationsTable();
        });

        $("#client_status_remote_peer").keydown(function() {
            if ($(this).val() == NRS.state.apiProxyPeer) {
                $("#client_status_set_peer").prop('disabled', true);
                $("#client_status_blacklist_peer").prop('disabled', false);
            } else {
                $("#client_status_set_peer").prop('disabled', false);
                $("#client_status_blacklist_peer").prop('disabled', true);
            }
        });

        // fixes popover hovering over dropdown menu
        $('#header_right li.dropdown.show_popover').on('shown.bs.dropdown', function () {
            $(this).popover('hide');
        });

        NRS.forms.setAPIProxyPeer = function ($modal) {
            var data = NRS.getFormData($modal.find("form:first"));
            data.adminPassword = NRS.getAdminPassword();
            return {
                "data": data
            };
        };

        NRS.forms.setAPIProxyPeerComplete = function(response) {
            var announcedAddress = response.announcedAddress;
            if (announcedAddress) {
                NRS.state.apiProxyPeer = announcedAddress;
                $.growl($.t("remote_peer_updated", { peer: String(announcedAddress).escapeHTML() }));
            } else {
                $.growl($.t("remote_peer_selected_by_server"));
            }
            NRS.updateDashboardMessage();
        };

        NRS.forms.blacklistAPIProxyPeer = function ($modal) {
            var data = NRS.getFormData($modal.find("form:first"));
            data.adminPassword = NRS.getAdminPassword();
            return {
                "data": data
            };
        };

        NRS.forms.blacklistAPIProxyPeerComplete = function(response) {
            if (response.done) {
                NRS.state.apiProxyPeer = null;
                $.growl($.t("remote_peer_blacklisted"));
            }
            NRS.updateDashboardMessage();
        };

        $("#passphrase_validation_modal").on("show.bs.modal", function() {
            $(this).find("button.btn-primary").show();
            $(this).find("input[name=secretPhrase]").attr("readonly", false);
            $("#passphrae_validation_account").val(NRS.accountRS);
        });

        NRS.forms.validatePassphrase = function($modal) {
            let data = NRS.getFormData($modal.find("form:first"));
            let secretPhrase = data.secretPhrase;
            if (!secretPhrase) {
                return {
                    "error": $.t("empty_passphrase_private_key"),
                    "stop": true,
                    "keepOpen": true
                };
            }
            let privateKey = NRS.getPrivateKey(secretPhrase);
            let accountRs = data.account;
            let address = NRS.createRsAddress();
            address.set(accountRs);
            let accountId = address.account_id();
            let calculatedAccount = NRS.getAccountId(privateKey);
            if (accountId === calculatedAccount) {
                $(".btn-passphrase-validation").removeClass("btn-danger").addClass("btn-success");
                var publicKey = NRS.getPublicKeyFromSecretPhrase(secretPhrase);
                $("#passphrae_validation_public_key").val(publicKey);
                $modal.find("button.btn-primary").hide();
                $modal.find("input[name=secretPhrase]").attr("readonly", true);
                return {
                    "successMessage": $.t("correct_passphrase_private_key"),
                    "stop": true,
                    "keepOpen": true
                };
            } else {
                $("#passphrae_validation_public_key").val("");
                return {
                    "error": $.t("wrong_passphrase_private_key"),
                    "stop": true,
                    "keepOpen": true
                };
            }
        };

        NRS.getPassphraseValidationLink = function(isPassphraseLogin) {
            if (NRS.isDisablePassphraseValidation()) {
                return "";
            }
            var label;
            if (isPassphraseLogin) {
                label = $.t("validate_passphrase");
            } else {
                label = $.t("account_public_key");
            }
            return "<br/><a href='#' class='btn btn-xs btn-danger btn-passphrase-validation' data-toggle='modal' data-target='#passphrase_validation_modal'>" + label + "</a>";
        };

        return NRS;
    }(NRS || {}, jQuery));
});