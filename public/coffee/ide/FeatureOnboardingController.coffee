define [
	"base"
], (App) ->
	App.controller "FeatureOnboardingController", ($scope, settings) ->
		$scope.innerStep = 1

		$scope.turnCodeCheckOn = () ->
			settings.saveSettings({ syntaxValidation: true })
			$scope.settings.syntaxValidation = true
			navToInnerStep2()
			
		$scope.turnCodeCheckOff = () ->
			settings.saveSettings({ syntaxValidation: false })
			$scope.settings.syntaxValidation = false
			navToInnerStep2()

		$scope.dismiss = () ->
			$scope.ui.leftMenuShown = false
			$scope.ui.showCodeCheckerOnboarding = false

		navToInnerStep2 = () ->
			$scope.innerStep = 2
			$scope.ui.leftMenuShown = true

		handleKeypress = (e) ->
			if e.keyCode == 13
				if $scope.innerStep == 1
					$scope.turnCodeCheckOn()
				else
					$scope.dismiss()

		$(document).on "keypress", handleKeypress

		$scope.$on "$destroy", () -> 
			$(document).off "keypress", handleKeypress