define [
	"ace/ace"
], () ->
	Range = ace.require("ace/range").Range
	EditSession = ace.require("ace/edit_session").EditSession
	Doc = ace.require("ace/document").Document

	class UndoManager
		constructor: (@$scope, @editor) ->
			@$scope.undo =
				show_remote_warning: false
				
			@reset()
			@nextUpdateIsRemote = false

			@editor.on "changeSession", (e) =>
				@reset()
				e.session.setUndoManager(@)

		showUndoConflictWarning: () ->
			@$scope.$apply () =>
				@$scope.undo.show_remote_warning = true

			setTimeout () => 
				@$scope.$apply () =>
					@$scope.undo.show_remote_warning = false
			, 4000

		reset: () ->
			@firstUpdate = true
			@undoStack = []
			@redoStack = []

		execute: (options) ->
			if @firstUpdate
				# The first update we receive is Ace setting the document, which we should
				# ignore
				@firstUpdate = false
				return
			aceDeltaSets = options.args[0]
			@session = options.args[1]
			return if !aceDeltaSets?

			lines = @session.getDocument().getAllLines()
			linesBeforeChange = @_revertAceDeltaSetsOnDocLines(aceDeltaSets, lines)
			simpleDeltaSets = @_aceDeltaSetsToSimpleDeltaSets(aceDeltaSets, linesBeforeChange)
			@undoStack.push(
				deltaSets: simpleDeltaSets
				remote: @nextUpdateIsRemote
			)
			@redoStack = []
			@nextUpdateIsRemote = false

		undo: (dontSelect) ->
			localUpdatesMade = @_shiftLocalChangeToTopOfUndoStack()
			return if !localUpdatesMade

			update = @undoStack.pop()
			return if !update?

			if update.remote
				@showUndoConflictWarning()

			lines = @session.getDocument().getAllLines()
			linesBeforeDelta = @_revertSimpleDeltaSetsOnDocLines(update.deltaSets, lines)
			deltaSets = @_simpleDeltaSetsToAceDeltaSets(update.deltaSets, linesBeforeDelta)
			selectionRange = @session.undoChanges(deltaSets, dontSelect)
			@redoStack.push(update)
			return selectionRange
		
		redo: (dontSelect) ->
			update = @redoStack.pop()
			return if !update?
			lines = @session.getDocument().getAllLines()
			deltaSets = @_simpleDeltaSetsToAceDeltaSets(update.deltaSets, lines)
			selectionRange = @session.redoChanges(deltaSets, dontSelect)
			@undoStack.push(update)
			return selectionRange

		_shiftLocalChangeToTopOfUndoStack: () ->
			head = []
			localChangeExists = false
			while @undoStack.length > 0
				update = @undoStack.pop()
				head.unshift update
				if !update.remote
					localChangeExists = true
					break

			if !localChangeExists
				@undoStack = @undoStack.concat head
				return false
			else
				# Undo stack looks like undoStack ++ reorderedhead ++ head
				# Reordered head starts of empty and consumes entries from head
				# while keeping the localChange at the top for as long as it can
				localChange = head.shift()
				reorderedHead = [localChange]
				while head.length > 0
					remoteChange = head.shift()
					localChange = reorderedHead.pop()
					result = @_swapSimpleDeltaSetsOrder(localChange.deltaSets, remoteChange.deltaSets)
					if result?
						remoteChange.deltaSets = result[0]
						localChange.deltaSets = result[1]
						reorderedHead.push remoteChange
						reorderedHead.push localChange
					else
						reorderedHead.push localChange
						reorderedHead.push remoteChange
						break
				@undoStack = @undoStack.concat(reorderedHead).concat(head)
				return true
				

		_swapSimpleDeltaSetsOrder: (firstDeltaSets, secondDeltaSets) ->
			newFirstDeltaSets = @_copyDeltaSets(firstDeltaSets)
			newSecondDeltaSets = @_copyDeltaSets(secondDeltaSets)
			for firstDeltaSet in newFirstDeltaSets.slice(0).reverse()
				for firstDelta in firstDeltaSet.deltas.slice(0).reverse()
					for secondDeltaSet in newSecondDeltaSets
						for secondDelta in secondDeltaSet.deltas
							success = @_swapSimpleDeltaOrderInPlace(firstDelta, secondDelta)
							return null if !success
			return [newSecondDeltaSets, newFirstDeltaSets]

		_copyDeltaSets: (deltaSets) ->
			newDeltaSets = []
			for deltaSet in deltaSets
				newDeltaSet =
					deltas: []
					group: deltaSet.group
				newDeltaSets.push newDeltaSet
				for delta in deltaSet.deltas
					newDelta =
						position: delta.position
					newDelta.insert = delta.insert if delta.insert?
					newDelta.remove = delta.remove if delta.remove?
					newDeltaSet.deltas.push newDelta
			return newDeltaSets

		_swapSimpleDeltaOrderInPlace: (firstDelta, secondDelta) ->
			result = @_swapSimpleDeltaOrder(firstDelta, secondDelta)
			return false if !result?
			firstDelta.position = result[1].position
			secondDelta.position = result[0].position
			return true

		_swapSimpleDeltaOrder: (firstDelta, secondDelta) ->
			if firstDelta.insert? and secondDelta.insert?
				if secondDelta.position >= firstDelta.position + firstDelta.insert.length
					secondDelta.position -= firstDelta.insert.length
					return [secondDelta, firstDelta]
				else if secondDelta.position > firstDelta.position
					return null
				else
					firstDelta.position += secondDelta.insert.length
					return [secondDelta, firstDelta]
			else if firstDelta.remove? and secondDelta.remove?
				if secondDelta.position >= firstDelta.position
					secondDelta.position += firstDelta.remove.length
					return [secondDelta, firstDelta]
				else if secondDelta.position + secondDelta.remove.length > firstDelta.position
					return null
				else
					firstDelta.position -= secondDelta.remove.length
					return [secondDelta, firstDelta]
			else if firstDelta.insert? and secondDelta.remove?
				if secondDelta.position >= firstDelta.position + firstDelta.insert.length
					secondDelta.position -= firstDelta.insert.length
					return [secondDelta, firstDelta]
				else if secondDelta.position + secondDelta.remove.length > firstDelta.position
					return null
				else
					firstDelta.position -= secondDelta.remove.length
					return [secondDelta, firstDelta]
			else if firstDelta.remove? and secondDelta.insert?
				if secondDelta.position >= firstDelta.position
					secondDelta.position += firstDelta.remove.length
					return [secondDelta, firstDelta]
				else
					firstDelta.position += secondDelta.insert.length
					return [secondDelta, firstDelta]
			else
				throw "Unknown delta types"

		_applyAceDeltasToDocLines: (deltas, docLines) ->
			doc = new Doc(docLines.join("\n"))
			doc.applyDeltas(deltas)
			return doc.getAllLines()

		_revertAceDeltaSetsOnDocLines: (deltaSets, docLines) ->
			session = new EditSession(docLines.join("\n"))
			session.undoChanges(deltaSets)
			return session.getDocument().getAllLines()

		_revertSimpleDeltaSetsOnDocLines: (deltaSets, docLines) ->
			doc = docLines.join("\n")
			for deltaSet in deltaSets.slice(0).reverse()
				for delta in deltaSet.deltas.slice(0).reverse()
					if delta.remove?
						doc = doc.slice(0, delta.position) + delta.remove + doc.slice(delta.position)
					else if delta.insert?
						doc = doc.slice(0, delta.position) + doc.slice(delta.position + delta.insert.length)
					else
						throw "Unknown delta type"
			return doc.split("\n")

		_aceDeltaSetsToSimpleDeltaSets: (aceDeltaSets, docLines) ->
			simpleDeltaSets = []
			for deltaSet in aceDeltaSets
				if deltaSet.group == "doc" # ignore fold changes
					simpleDeltas = []
					for delta in deltaSet.deltas
						simpleDeltas.push @_aceDeltaToSimpleDelta(delta, docLines)
						docLines = @_applyAceDeltasToDocLines([delta], docLines)
					simpleDeltaSets.push {
						deltas: simpleDeltas
						group: deltaSet.group
					}
			return simpleDeltaSets

		_simpleDeltaSetsToAceDeltaSets: (simpleDeltaSets, docLines) ->
			for deltaSet in simpleDeltaSets
				aceDeltas = []
				for delta in deltaSet.deltas
					newAceDeltas = @_simpleDeltaToAceDeltas(delta, docLines)
					docLines = @_applyAceDeltasToDocLines(newAceDeltas, docLines)
					aceDeltas = aceDeltas.concat newAceDeltas
				{
					deltas: aceDeltas
					group: deltaSet.group
				}

		_aceDeltaToSimpleDelta: (aceDelta, docLines) ->
			start = aceDelta.start
			if !start?
				JSONstringifyWithCycles = (o) ->
					seen = []
					return JSON.stringify o, (k,v) ->
						if (typeof v == 'object')
							if ( seen.indexOf(v) >= 0 )
								return '__cycle__'
							seen.push(v);
						return v
				error = new Error("aceDelta had no start event: #{JSONstringifyWithCycles(aceDelta)}")
				throw error
			linesBefore = docLines.slice(0, start.row)
			position =
				linesBefore.join("").length + # full lines
				linesBefore.length + # new line characters
				start.column # partial line
			switch aceDelta.action
				when "insert"
					simpleDelta = {
						position: position
						insert: aceDelta.lines.join("\n")
					}
				when "remove"
					simpleDelta = {
						position: position
						remove: aceDelta.lines.join("\n")
					}
				else
					throw new Error("Unknown Ace action: #{aceDelta.action}")
			return simpleDelta

		_simplePositionToAcePosition: (position, docLines) ->
			column = 0
			row = 0
			for line in docLines
				if position > line.length
					row++
					position -= (line + "\n").length
				else
					column = position
					break
			return {row: row, column: column}

		_simpleDeltaToAceDeltas: (simpleDelta, docLines) ->
			{row, column} = @_simplePositionToAcePosition(simpleDelta.position, docLines)

			lines = (simpleDelta.insert or simpleDelta.remove or "").split("\n")
			
			start = {column, row}
			if lines.length > 1
				end = {
					row: row + lines.length - 1,
					column: lines[lines.length - 1].length
				}
			else
				end = {
					row,
					column: column + lines[0].length
				}
			
			if simpleDelta.insert?
				aceDelta = {
					action: "insert"
					lines, start, end
				}
			else if simpleDelta.remove?
				aceDelta = {
					action: "remove"
					lines, start, end
				}
			else
				throw "Unknown simple delta: #{simpleDelta}"

			return [aceDelta]

		_concatSimpleDeltas: (deltas) ->
			return [] if deltas.length == 0

			concattedDeltas = []
			previousDelta = deltas.shift()
			for delta in deltas
				if delta.insert? and previousDelta.insert?
					if previousDelta.position + previousDelta.insert.length == delta.position
						previousDelta =
							insert: previousDelta.insert + delta.insert
							position: previousDelta.position
					else
						concattedDeltas.push previousDelta
						previousDelta = delta

				else if delta.remove? and previousDelta.remove?
					if previousDelta.position == delta.position
						previousDelta =
							remove: previousDelta.remove + delta.remove
							position: delta.position
					else
						concattedDeltas.push previousDelta
						previousDelta = delta
				else
					concattedDeltas.push previousDelta
					previousDelta = delta
			concattedDeltas.push previousDelta
					

			return concattedDeltas
				

		hasUndo: () -> @undoStack.length > 0
		hasRedo: () -> @redoStack.length > 0
		
